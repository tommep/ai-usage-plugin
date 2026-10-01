import SwiftUI

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var settings: SystemSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard(title: "Menu bar", symbol: "menubar.rectangle") {
                VStack(spacing: 9) {
                    settingRow("Labels") {
                        Picker("Provider labels", selection: $preferences.providerLabels) {
                            ForEach(ProviderLabelStyle.allCases) { style in Text(style.title).tag(style) }
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    settingRow("Show") {
                        Picker("Percentage", selection: $preferences.display) {
                            ForEach(DisplayMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    Divider().overlay(.white.opacity(0.04)).padding(.vertical, 1)
                    ForEach(Provider.allCases) { provider in
                        HStack(spacing: 7) {
                            Image(nsImage: ProviderArtwork.image(provider))
                                .resizable().scaledToFit().frame(width: 18, height: 18).accessibilityHidden(true)
                            Text(provider.rawValue).font(.system(size: 11, weight: .medium))
                            Spacer()
                            Picker("\(provider.rawValue) menu bar window", selection: Binding(get: { preferences.choice(provider) }, set: { preferences.choices[provider] = $0 })) {
                                ForEach(WindowChoice.allCases) { choice in Text(choice.title).tag(choice) }
                            }.pickerStyle(.menu).labelsHidden().controlSize(.small).frame(width: 128)
                        }.frame(height: 22)
                    }
                }
            }
            SettingsCard(title: "App behavior", symbol: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: 9) {
                    VStack(alignment: .leading, spacing: 3) {
                        behaviorToggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                        hint("Start automatically when you log in.")
                        if settings.loginNeedsApproval {
                            Button("Approve in Login Items") { settings.openLoginSettings() }
                                .buttonStyle(.plain).foregroundStyle(Palette.codex).font(.system(size: 10))
                        }
                    }
                    Divider().overlay(.white.opacity(0.04))
                    VStack(alignment: .leading, spacing: 3) {
                        behaviorToggle("Usage alerts", isOn: Binding(get: { settings.alertsEnabled }, set: { enabled in Task { await settings.setAlerts(enabled) } }))
                            .disabled(settings.busy)
                        hint("At 80% and 95%, and after an exhausted allowance resets.")
                    }
                    HStack(spacing: 8) {
                        action("Notification settings") { settings.openNotificationSettings() }
                        if settings.alertsEnabled {
                            action("Test alert") { Task { await settings.testAlert() } }
                        }
                    }
                }.tint(Palette.codex)
            }
            if let message = settings.message {
                Text(message).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 3)
            }
        }.font(.system(size: 11))
    }

    private func settingRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(Palette.muted).frame(width: 48, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func behaviorToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .medium))
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }

    private func action(_ title: String, perform: @escaping () -> Void) -> some View {
        Button(title, action: perform).buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.codex)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            content
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
