import AppKit
import ServiceManagement
import UserNotifications
import SwiftUI

@MainActor
final class SystemSettings: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var alertsEnabled = false
    @Published private(set) var busy = false
    @Published var message: String?
    var onAlertsChanged: (() -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    func refresh() async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let status = await center.notificationSettings().authorizationStatus
        alertsEnabled = defaults.bool(forKey: "usageAlertsEnabled") && (status == .authorized || status == .provisional)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        message = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
            if loginNeedsApproval { message = "Approve AI Usage in System Settings → Login Items." }
        } catch { message = "Couldn’t change launch at login. Try again in System Settings." }
    }

    func setAlerts(_ enabled: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        message = nil
        if !enabled {
            defaults.set(false, forKey: "usageAlertsEnabled")
            alertsEnabled = false
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            onAlertsChanged?()
            return
        }
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            defaults.set(allowed, forKey: "usageAlertsEnabled")
            alertsEnabled = allowed
            onAlertsChanged?()
            if !allowed { message = "Allow notifications for AI Usage in System Settings → Notifications." }
        } catch { message = "Couldn’t enable alerts. Check System Settings → Notifications." }
    }

    func send(_ alert: UsageAlert, now: Date) async {
        guard alertsEnabled else { return }
        let content = UNMutableNotificationContent()
        switch alert.kind {
        case .threshold(let percent):
            content.title = "\(alert.provider.rawValue): \(percent)% used"
            content.body = "\(alert.window.title) allowance. Resets in \(alert.window.countdown(at: now))."
        case .reset:
            content.title = "\(alert.provider.rawValue) allowance is available again"
            content.body = "Your \(alert.window.title.lowercased()) window has renewed. \(Int((100 - alert.window.used).rounded()))% remains."
        }
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil))
        } catch { message = "An alert couldn’t be queued. Check your notification settings." }
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func openNotificationSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }

    func testAlert() async {
        guard alertsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "AI Usage alerts are ready"
        content.body = "You’ll be notified at 80% and 95% usage, and when an exhausted allowance renews."
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "usage.test", content: content, trigger: nil))
            message = "Test alert queued. Focus settings may silence banners."
        } catch { message = "Couldn’t queue the test alert. Check notification settings." }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
