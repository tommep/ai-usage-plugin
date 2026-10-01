import AppKit
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshots: [Provider: UsageSnapshot] = [:]
    @Published var failures: [Provider: UsageFailure] = [:]
    @Published var refreshing: Set<Provider> = []
    @Published var reconnecting: Set<Provider> = []
    @Published var now = Date()
    let preferences: Preferences
    let settings: SystemSettings
    var onChange: (() -> Void)?
    private var lastAttempt: [Provider: Date] = [:]
    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private let fetcher: (Provider) async throws -> UsageSnapshot
    private var alertTracker: UsageAlertTracker
    private var signIns: [Provider: SignInAttempt] = [:]
    private var reconnectLoop: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?
    private let cacheDefaults: UserDefaults?
    private var restoredProviders: Set<Provider> = []
    private static let cacheKey = "lastKnownUsage.v1"

    init(defaults: UserDefaults? = nil, preferences: Preferences? = nil, settings: SystemSettings? = nil, fetcher: @escaping (Provider) async throws -> UsageSnapshot = ProviderClient.fetch) {
        self.fetcher = fetcher
        self.cacheDefaults = defaults
        self.preferences = preferences ?? Preferences(defaults: defaults ?? .standard)
        self.settings = settings ?? SystemSettings(defaults: defaults ?? .standard)
        alertTracker = UsageAlertTracker(defaults: defaults)
        if let data = defaults?.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([String: UsageSnapshot].self, from: data) {
            for provider in Provider.allCases {
                guard let snapshot = cached[provider.rawValue], !snapshot.windows.isEmpty,
                      snapshot.windows.allSatisfy({ UsageParser.valid($0.used) && $0.minutes > 0 }) else { continue }
                snapshots[provider] = snapshot
                restoredProviders.insert(provider)
            }
        }
        self.preferences.onChange = { [weak self] in self?.objectWillChange.send(); self?.onChange?() }
        self.settings.onAlertsChanged = { [weak self] in
            guard let self else { return }
            self.alertTracker.clear()
            for (provider, snapshot) in self.snapshots { _ = self.alertTracker.observe(snapshot, provider: provider, now: Date()) }
        }
    }

    func stop() {
        loop?.cancel()
        reconnectLoop?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
    }

    func start() {
        Task { await settings.refresh() }
        refresh()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                self.now = Date()
                for provider in Provider.allCases {
                    let wait: Double = self.failures[provider] == .throttled ? 900 : 300
                    if self.now.timeIntervalSince(self.lastAttempt[provider] ?? .distantPast) >= wait { self.refresh(provider) }
                }
                self.onChange?()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.now = Date(); self?.refresh() }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.checkSignIns(); await self?.settings.refresh() }
        }
    }

    func refresh(_ provider: Provider? = nil, afterSignIn: Bool = false) {
        for provider in provider.map({ [$0] }) ?? Provider.allCases {
            guard !refreshing.contains(provider) else { continue }
            // Back off rate-limited providers even if Refresh is clicked repeatedly.
            if !afterSignIn, failures[provider] == .throttled, Date().timeIntervalSince(lastAttempt[provider] ?? .distantPast) < 900 { continue }
            refreshing.insert(provider)
            lastAttempt[provider] = Date()
            Task {
                do {
                    let snapshot = try await fetcher(provider)
                    snapshots[provider] = snapshot
                    restoredProviders.remove(provider)
                    saveSnapshots()
                    failures.removeValue(forKey: provider)
                    if settings.alertsEnabled {
                        let events = alertTracker.observe(snapshot, provider: provider, now: Date())
                        for event in events { await settings.send(event, now: Date()) }
                    }
                } catch {
                    let failure = (error as? UsageFailure) ?? .unavailable
                    failures[provider] = failure
                    // A revoked/changed login invalidates the old account's usage.
                    if failure == .signIn {
                        snapshots.removeValue(forKey: provider)
                        restoredProviders.remove(provider)
                        saveSnapshots()
                        alertTracker.clear(provider)
                    }
                }
                refreshing.remove(provider)
                if afterSignIn { reconnecting.remove(provider) }
                now = Date()
                onChange?()
            }
        }
    }

    // Keep the selected window's last reading, even after its reset passes.
    // It must remain stale until the provider supplies replacement evidence.
    func lastKnownWindow(_ provider: Provider) -> UsageWindow? {
        guard let windows = snapshots[provider]?.windows else { return nil }
        return preferences.choice(provider) == .weekly
            ? windows.max { $0.minutes < $1.minutes }
            : windows.min { $0.minutes < $1.minutes }
    }

    func isStale(_ provider: Provider) -> Bool {
        guard let snapshot = snapshots[provider], let window = lastKnownWindow(provider) else { return false }
        return restoredProviders.contains(provider) || failures[provider] != nil || !snapshot.isFresh(at: now) || !window.active(at: now)
    }

    private func saveSnapshots() {
        let cached = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(cached) { cacheDefaults?.set(data, forKey: Self.cacheKey) }
    }

    func staleMessage(_ provider: Provider) -> String? {
        guard isStale(provider) else { return nil }
        if failures[provider] == .throttled {
            let seconds = max(0, 900 - now.timeIntervalSince(lastAttempt[provider] ?? now))
            let retry = seconds > 0 ? "Retrying in \(Int(ceil(seconds / 60))) min." : "Retrying shortly."
            return "Showing last known usage. Provider is limiting refreshes. \(retry)"
        }
        if let failure = failures[provider] {
            return "Showing last known usage. \(failure.localizedDescription)"
        }
        return "Showing last known usage. Waiting for updated usage data."
    }

    func signIn(_ provider: Provider) {
        do {
            guard !reconnecting.contains(provider), let attempt = try SignInLauncher.open(provider) else { return }
            watchSignIn(provider, attempt: attempt)
        } catch { failures[provider] = .unavailable }
    }

    func watchSignIn(_ provider: Provider, attempt: SignInAttempt) {
        signIns[provider] = attempt
        reconnecting.insert(provider)
        alertTracker.clear(provider)
        if reconnectLoop == nil {
            reconnectLoop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self else { return }
                    self.checkSignIns()
                    if self.signIns.isEmpty { self.reconnectLoop = nil; return }
                }
            }
        }
    }

    func cancelSignIn(_ provider: Provider) {
        if let attempt = signIns.removeValue(forKey: provider) { try? FileManager.default.removeItem(at: attempt.marker) }
        reconnecting.remove(provider)
    }

    func checkSignIns() {
        for (provider, attempt) in signIns {
            if Date().timeIntervalSince(attempt.started) > 600 { cancelSignIn(provider); continue }
            guard attempt.hasCompleted(), !refreshing.contains(provider) else { continue }
            signIns.removeValue(forKey: provider)
            try? FileManager.default.removeItem(at: attempt.marker)
            snapshots.removeValue(forKey: provider)
            restoredProviders.remove(provider)
            saveSnapshots()
            refresh(provider, afterSignIn: true)
        }
    }
}
