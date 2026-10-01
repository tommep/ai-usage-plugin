import XCTest
@testable import AIUsage

final class ImprovementTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_000_000)
    func snapshot(_ used: Double, second: Double, reset: Double = 1000) -> UsageSnapshot {
        UsageSnapshot(windows: [UsageWindow(id: "weekly", title: "Weekly", used: used, resetsAt: base.addingTimeInterval(reset), minutes: 10080)], observedAt: base.addingTimeInterval(second), plan: nil)
    }
    func observe(_ tracker: inout UsageAlertTracker, _ used: Double, second: Double, reset: Double = 1000) -> [UsageAlert] {
        tracker.observe(snapshot(used, second: second, reset: reset), provider: .codex, now: base.addingTimeInterval(second))
    }

    func testAlertsCrossThresholdsOnceEvenIfUsageDrops() {
        var tracker = UsageAlertTracker()
        XCTAssertTrue(observe(&tracker, 79, second: 0).isEmpty)
        XCTAssertEqual(observe(&tracker, 81, second: 1).map(\.kind), [.threshold(80)])
        XCTAssertTrue(observe(&tracker, 75, second: 2).isEmpty)
        XCTAssertTrue(observe(&tracker, 82, second: 3).isEmpty)
        XCTAssertEqual(observe(&tracker, 95, second: 4).map(\.kind), [.threshold(95)])
        XCTAssertTrue(observe(&tracker, 99, second: 5).isEmpty)
    }

    func testAlertsBeginQuietlyAndCombineLargeJumps() {
        var tracker = UsageAlertTracker()
        XCTAssertTrue(observe(&tracker, 96, second: 0).isEmpty)
        tracker.clear()
        _ = observe(&tracker, 10, second: 1)
        XCTAssertEqual(observe(&tracker, 96, second: 2).map(\.kind), [.threshold(95)])
        XCTAssertTrue(observe(&tracker, 81, second: 3).isEmpty)
    }

    func testResetNeedsExhaustionAndNewProviderEvidence() {
        var tracker = UsageAlertTracker()
        _ = observe(&tracker, 100, second: 0)
        XCTAssertTrue(observe(&tracker, 100, second: 1001).isEmpty)
        XCTAssertEqual(observe(&tracker, 2, second: 1002, reset: 2000).map(\.kind), [.reset])
        XCTAssertTrue(observe(&tracker, 2, second: 1003, reset: 2000).isEmpty)
        tracker.clear()
        _ = observe(&tracker, 95, second: 0)
        XCTAssertTrue(observe(&tracker, 0, second: 1002, reset: 2000).isEmpty)
    }

    func testOldAndStaleEvidenceCannotTriggerAlerts() {
        var tracker = UsageAlertTracker()
        _ = observe(&tracker, 50, second: 20)
        XCTAssertTrue(observe(&tracker, 96, second: 10).isEmpty)
        XCTAssertTrue(tracker.observe(snapshot(99, second: 21), provider: .codex, now: base.addingTimeInterval(700)).isEmpty)
        XCTAssertEqual(observe(&tracker, 81, second: 22).map(\.kind), [.threshold(80)])
    }

    func testAlertsPersistWithoutRepeatingAfterRestart() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var tracker = UsageAlertTracker(defaults: defaults)
        _ = observe(&tracker, 50, second: 0)
        _ = observe(&tracker, 81, second: 1)
        var restarted = UsageAlertTracker(defaults: defaults)
        XCTAssertTrue(observe(&restarted, 82, second: 2).isEmpty)
        XCTAssertEqual(observe(&restarted, 96, second: 3).map(\.kind), [.threshold(95)])
    }

    @MainActor
    func testIndependentPreferencesPersistAndMigrateOldChoice() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "weekly")
        let preferences = Preferences(defaults: defaults)
        XCTAssertEqual(preferences.choice(.codex), .weekly)
        preferences.choices[.claude] = .short
        preferences.display = .remaining
        let restarted = Preferences(defaults: defaults)
        XCTAssertEqual(restarted.choice(.codex), .weekly)
        XCTAssertEqual(restarted.choice(.claude), .short)
        XCTAssertEqual(restarted.display, .remaining)
        XCTAssertEqual(DisplayMode.remaining.percentage(100), 0)
        XCTAssertEqual(DisplayMode.remaining.percentage(0), 100)
    }

    @MainActor
    func testProviderWindowsAreSelectedIndependently() {
        let suite = "AIUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.choices = [.codex: .weekly, .claude: .short]
        let store = UsageStore(preferences: preferences)
        let now = Date()
        let windows = [UsageWindow(id: "short", title: "5-hour", used: 10, resetsAt: now.addingTimeInterval(300), minutes: 300), UsageWindow(id: "week", title: "Weekly", used: 60, resetsAt: now.addingTimeInterval(600), minutes: 10080)]
        store.snapshots = [.codex: UsageSnapshot(windows: windows, observedAt: now, plan: nil), .claude: UsageSnapshot(windows: windows, observedAt: now, plan: nil)]
        XCTAssertEqual(store.featured(.codex)?.used, 60)
        XCTAssertEqual(store.featured(.claude)?.used, 10)
    }

    func testSignInCompletionUsesMarkerOrChangedCredentialFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("completed")
        let credential = folder.appendingPathComponent("fictional-login")
        let attempt = SignInAttempt(marker: marker, credentialFile: credential, initialModification: nil, started: Date())
        XCTAssertFalse(attempt.hasCompleted())
        try Data("fictional test data".utf8).write(to: credential)
        XCTAssertTrue(attempt.hasCompleted())
        try FileManager.default.removeItem(at: credential)
        try Data().write(to: marker)
        XCTAssertTrue(attempt.hasCompleted())
    }

    @MainActor
    func testCompletedSignInRefreshesProviderWithoutManualClick() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("completed")
        let attempt = SignInAttempt(marker: marker, credentialFile: folder.appendingPathComponent("fictional-login"), initialModification: nil, started: Date())
        let received = snapshot(6, second: 0)
        var reads: [Provider] = []
        let store = UsageStore(fetcher: { provider in reads.append(provider); return received })
        defer { store.stop() }
        store.failures[.claude] = .signIn
        store.watchSignIn(.claude, attempt: attempt)
        store.checkSignIns()
        XCTAssertTrue(reads.isEmpty)
        XCTAssertTrue(store.reconnecting.contains(.claude))
        try Data().write(to: marker)
        store.checkSignIns()
        for _ in 0..<100 where store.refreshing.contains(.claude) { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(reads, [.claude])
        XCTAssertEqual(store.snapshots[.claude]?.windows.first?.used, 6)
        XCTAssertNil(store.failures[.claude])
        XCTAssertFalse(store.reconnecting.contains(.claude))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
