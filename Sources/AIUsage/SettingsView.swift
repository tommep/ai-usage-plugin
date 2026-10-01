import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var settings: SystemSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("MENU BAR").font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.muted)
                Picker("Percentage", selection: $preferences.display) {
                    ForEach(DisplayMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented)
                ForEach(Provider.allCases) { provider in
                    Picker(provider.rawValue, selection: Binding(get: { preferences.choice(provider) }, set: { preferences.choices[provider] = $0 })) {
                        ForEach(WindowChoice.allCases) { choice in Text(choice.title).tag(choice) }
                    }.pickerStyle(.menu)
                }
            }
            Divider().overlay(.white.opacity(0.06))
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) })).toggleStyle(.switch)
                if settings.loginNeedsApproval {
                    Button("Approve in Login Items") { settings.openLoginSettings() }.buttonStyle(.plain).foregroundStyle(Palette.codex)
                }
                Text("Keep your meters ready after restarting your Mac.").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            Divider().overlay(.white.opacity(0.06))
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Usage alerts", isOn: Binding(get: { settings.alertsEnabled }, set: { enabled in Task { await settings.setAlerts(enabled) } }))
                    .toggleStyle(.switch).disabled(settings.busy)
                Text("Once at 80% and 95%, and when an exhausted allowance renews. No sounds.")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                Button("Notification settings") { settings.openNotificationSettings() }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.codex)
                if settings.alertsEnabled {
                    Button("Send test alert") { Task { await settings.testAlert() } }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.codex)
                }
            }
            if let message = settings.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.system(size: 12)).padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 13))
    }
}
