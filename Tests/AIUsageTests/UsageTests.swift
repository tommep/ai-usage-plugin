import XCTest
@testable import AIUsage

final class UsageTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func testPopoverStaysInsideSmallScreenAtEveryEdge() {
        let screen = CGRect(x: 0, y: 40, width: 800, height: 560)
        let size = PopoverLayout.contentSize(in: screen)
        XCTAssertEqual(size.height, 500)
        for point in [CGPoint(x: -100, y: -300), CGPoint(x: 700, y: 500), CGPoint(x: 0, y: 50)] {
            let frame = PopoverLayout.constrained(CGRect(origin: point, size: size), to: screen)
            XCTAssertTrue(screen.contains(frame))
            XCTAssertEqual(frame.size, size)
        }
    }

    func testPopoverHandlesSecondaryDisplayWithNegativeOrigin() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1000)
        let frame = PopoverLayout.constrained(CGRect(x: -100, y: 700, width: 380, height: 600), to: screen)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.maxX, screen.maxX - 8)
        XCTAssertEqual(frame.maxY, screen.maxY - 8)
    }
    func testCodexUsesNamedBucketAndActualWindow() throws {
        let data = Data(#"{"result":{"rateLimits":{"limitId":"other","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":1100000}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":47,"windowDurationMins":10080,"resetsAt":1100000},"secondary":null,"planType":"pro"}}}}"#.utf8)
        let snapshot = try UsageParser.codex(data, at: now)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].title, "Weekly")
        XCTAssertEqual(snapshot.windows[0].used, 47)
    }
    func testClaudeWindowsAndFractionalResetDates() throws {
        let data = Data(#"{"five_hour":{"utilization":0,"resets_at":"2026-10-01T20:00:00.000Z"},"seven_day":{"utilization":82.5,"resets_at":"2026-10-04T20:00:00Z"}}"#.utf8)
        let snapshot = try UsageParser.claude(data, at: now)
        XCTAssertEqual(snapshot.featured(weekly: false, at: now)?.used, 0)
        XCTAssertEqual(snapshot.featured(weekly: true, at: now)?.used, 82.5)
    }
    func testMissingAndInvalidDataNeverBecomeZero() {
        for body in [#"{"five_hour":null,"seven_day":null}"#, #"{"five_hour":{"utilization":120,"resets_at":"2026-10-01T20:00:00Z"}}"#, #"{"five_hour":{"utilization":50,"resets_at":"bad"}}"#] {
            XCTAssertThrowsError(try UsageParser.claude(Data(body.utf8), at: now))
        }
        XCTAssertThrowsError(try UsageParser.codex(Data(#"{"result":{"rateLimits":null}}"#.utf8), at: now))
    }
    func testExpiryAndFreshnessDoNotInventResetUsage() {
        let window = UsageWindow(id: "weekly", title: "Weekly", used: 90, resetsAt: now.addingTimeInterval(120), minutes: 10080)
        let snapshot = UsageSnapshot(windows: [window], observedAt: now, plan: nil)
        XCTAssertNotNil(snapshot.featured(weekly: true, at: now))
        XCTAssertNil(snapshot.featured(weekly: true, at: now.addingTimeInterval(120)))
        XCTAssertTrue(snapshot.isFresh(at: now.addingTimeInterval(599)))
        XCTAssertFalse(snapshot.isFresh(at: now.addingTimeInterval(600)))
        XCTAssertEqual(window.countdown(at: now.addingTimeInterval(120)), "Refreshing reset…")
    }

    func testInteractivePipeDoesNotWaitForFullBuffer() throws {
        let child = try ChildProcess(URL(fileURLWithPath: "/bin/sh"), ["-c", "printf 'ready\\n'; read reply; printf 'done\\n'"], timeout: 2)
        defer { child.close() }
        XCTAssertEqual(String(data: try XCTUnwrap(child.line()), encoding: .utf8), "ready")
        try child.send(["continue": true])
        XCTAssertEqual(String(data: try XCTUnwrap(child.line()), encoding: .utf8), "done")
        XCTAssertFalse(child.timedOut)
    }

    func testHungChildHasBoundedTimeout() throws {
        let child = try ChildProcess(URL(fileURLWithPath: "/bin/sleep"), ["3"], timeout: 0.1)
        defer { child.close() }
        let start = Date()
        XCTAssertThrowsError(try child.all())
        XCTAssertTrue(child.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    @MainActor
    func testRevokedLoginClearsOldUsage() async throws {
        let store = UsageStore(fetcher: { _ in throw UsageFailure.signIn })
        store.snapshots[.codex] = UsageSnapshot(windows: [UsageWindow(id: "weekly", title: "Weekly", used: 45, resetsAt: Date().addingTimeInterval(3600), minutes: 10080)], observedAt: Date(), plan: nil)
        store.refresh(.codex)
        while !store.refreshing.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(store.snapshots[.codex])
        XCTAssertNil(store.featured(.codex))
        XCTAssertEqual(store.failures[.codex], .signIn)
    }

    @MainActor
    func testFailedRefreshHidesMenuPercentageAndKeepsLastKnownForPanel() async throws {
        let store = UsageStore(fetcher: { _ in throw UsageFailure.unavailable })
        store.snapshots[.codex] = UsageSnapshot(windows: [UsageWindow(id: "weekly", title: "Weekly", used: 45, resetsAt: Date().addingTimeInterval(3600), minutes: 10080)], observedAt: Date(), plan: nil)
        store.refresh(.codex)
        while !store.refreshing.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(store.snapshots[.codex])
        XCTAssertNil(store.featured(.codex))
        XCTAssertEqual(store.failures[.codex], .unavailable)
    }
}
