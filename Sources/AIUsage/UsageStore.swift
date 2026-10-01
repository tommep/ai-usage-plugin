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

    init(defaults: UserDefaults? = nil, preferences: Preferences? = nil, settings: SystemSettings? = nil, fetcher: @escaping (Provider) async throws -> UsageSnapshot = ProviderClient.fetch) {
        self.fetcher = fetcher
        self.preferences = preferences ?? Preferences(defaults: defaults ?? .standard)
        self.settings = settings ?? SystemSettings(defaults: defaults ?? .standard)
        alertTracker = UsageAlertTracker(defaults: defaults)
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
                    let expired = self.snapshots[provider]?.windows.contains { !$0.active(at: self.now) } == true
                    let interval: Double = self.failures[provider] == .throttled ? 900 : 180
                    let wait = expired && self.failures[provider] != .throttled ? 60 : interval
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
                    failures.removeValue(forKey: provider)
                    if settings.alertsEnabled {
                        let events = alertTracker.observe(snapshot, provider: provider, now: Date())
                        for event in events { await settings.send(event, now: Date()) }
                    }
                } catch {
                    let failure = (error as? UsageFailure) ?? .unavailable
                    failures[provider] = failure
                    // A revoked/changed login invalidates the old account's usage.
                    if failure == .signIn { snapshots.removeValue(forKey: provider); alertTracker.clear(provider) }
                }
                refreshing.remove(provider)
                if afterSignIn { reconnecting.remove(provider) }
                now = Date()
                onChange?()
            }
        }
    }

    func featured(_ provider: Provider) -> UsageWindow? {
        guard failures[provider] == nil, let snapshot = snapshots[provider], snapshot.isFresh(at: now) else { return nil }
        return snapshot.featured(weekly: preferences.choice(provider) == .weekly, at: now)
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
            refresh(provider, afterSignIn: true)
        }
    }
}
