import SwiftUI

enum Palette {
    static let background = Color(red: 0.075, green: 0.08, blue: 0.09)
    static let surface = Color.white.opacity(0.045)
    static let codex = Color(red: 0.40, green: 0.86, blue: 0.71)
    static let claude = Color(red: 0.91, green: 0.62, blue: 0.46)
    static let muted = Color.white.opacity(0.55)
}

struct UsagePanel: View {
    @ObservedObject var store: UsageStore
    var size = CGSize(width: 380, height: 500)
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(showingSettings ? "Settings" : "AI Usage").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text(showingSettings ? "Make it work your way." : "Your allowances, at a glance.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button {
                    if showingSettings { showingSettings = false } else { store.refresh() }
                } label: {
                    Image(systemName: showingSettings ? "arrow.left" : "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium)).frame(width: 30, height: 30)
                }.buttonStyle(.plain).background(Palette.surface, in: Circle())
                    .disabled(!showingSettings && !store.refreshing.isEmpty)
                    .accessibilityLabel(showingSettings ? "Back to usage" : "Refresh usage")
            }

            ScrollView {
                if showingSettings {
                    SettingsView(preferences: store.preferences, settings: store.settings)
                } else {
                    VStack(spacing: 12) {
                        ForEach(Provider.allCases) { provider in ProviderRow(provider: provider, store: store) }
                    }.padding(.trailing, 2)
                }
            }.scrollIndicators(.automatic).frame(maxHeight: .infinity)

            HStack {
                Image(systemName: "lock.shield").font(.system(size: 10))
                Text("Local to your Mac").font(.system(size: 10))
                Spacer()
                Button {
                    showingSettings.toggle()
                    Task { await store.settings.refresh() }
                } label: { Image(systemName: showingSettings ? "chart.bar" : "gearshape").frame(width: 24, height: 24) }
                .buttonStyle(.plain).accessibilityLabel(showingSettings ? "Show usage" : "Settings")
                Menu {
                    Button("Open Codex usage") { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!) }
                    Button("Open Claude usage") { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
                    Divider()
                    Button("Quit AI Usage", role: .destructive) { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis").frame(width: 22, height: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More options")
            }.foregroundStyle(Palette.muted)
        }.padding(20).frame(width: size.width, height: size.height)
            .background(Palette.background).foregroundStyle(.white).preferredColorScheme(.dark)
    }
}

private struct ProviderRow: View {
    let provider: Provider
    @ObservedObject var store: UsageStore
    var tint: Color { provider == .codex ? Palette.codex : Palette.claude }
    var snapshot: UsageSnapshot? { store.snapshots[provider] }
    var featured: UsageWindow? { snapshot?.featured(weekly: store.preferences.choice(provider) == .weekly, at: store.now) }
    var fresh: Bool { snapshot?.isFresh(at: store.now) == true && store.failures[provider] == nil }
    var signingIn: Bool { store.reconnecting.contains(provider) }
    var busy: Bool { store.refreshing.contains(provider) }
    var shortWindowTitle: String {
        snapshot?.windows.filter { $0.minutes < 10080 }.min { $0.minutes < $1.minutes }?.title ?? WindowChoice.short.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: ProviderArtwork.image(provider))
                    .resizable().scaledToFit().frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                Text(provider.rawValue).font(.system(size: 14, weight: .semibold))
                Spacer()
                Menu {
                    Picker("", selection: Binding(get: { store.preferences.choice(provider) }, set: { store.preferences.choices[provider] = $0 })) {
                        ForEach(WindowChoice.allCases) { choice in
                            Text(choice == .short ? shortWindowTitle : choice.title).tag(choice)
                        }
                    }.pickerStyle(.inline).labelsHidden()
                } label: {
                    Text(featured?.title ?? store.preferences.choice(provider).title).font(.system(size: 10, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize().foregroundStyle(Palette.muted)
                .accessibilityLabel("\(provider.rawValue) menu bar window")
            }

            if let featured, !signingIn {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(store.preferences.display.percentage(featured.used))%")
                        .font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("\(store.preferences.display.title.lowercased())\(fresh ? "" : " · last known")")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Spacer()
                    Text(busy ? "Refreshing" : fresh ? "Connected" : "Stale")
                        .font(.system(size: 10)).foregroundStyle(fresh ? tint : Palette.muted)
                }
                meter(featured.used)
                ForEach(snapshot?.windows ?? []) { window in
                    HStack {
                        Text(window.title).font(.system(size: 11, weight: .medium))
                        Spacer()
                        Text(window.active(at: store.now) ? "\(Int(window.used.rounded()))% used · resets in \(window.countdown(at: store.now))" : "Waiting for reset data")
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(Palette.muted)
                    }.help("Reset: \(window.resetsAt.formatted(date: .complete, time: .shortened))")
                }
                if let failure = store.failures[provider] { Text(failure.localizedDescription).font(.system(size: 10)).foregroundStyle(Palette.muted) }
            } else {
                Text(signingIn ? "Finish signing in in your browser." : busy ? "Checking your usage…" : store.failures[provider]?.localizedDescription ?? "Waiting for current usage")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                if signingIn {
                    Button("Cancel sign-in") { store.cancelSignIn(provider) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(tint)
                } else if !busy {
                    Button {
                        if store.failures[provider] == .signIn || store.failures[provider] == .missingCLI { store.signIn(provider) }
                        else { store.refresh(provider) }
                    } label: {
                        HStack { Text(store.failures[provider] == .signIn ? "Reconnect \(provider.rawValue)" : store.failures[provider] == .missingCLI ? "Get \(provider.rawValue)" : "Try again"); Spacer(); Image(systemName: "arrow.up.right") }
                            .font(.system(size: 11, weight: .semibold)).padding(9)
                    }.buttonStyle(.plain).foregroundStyle(tint).background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.055), lineWidth: 1))
    }

    private func meter(_ used: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.07))
                Capsule().fill(fresh ? (used >= 90 ? Color.orange : tint) : Color.gray)
                    .frame(width: geometry.size.width * (store.preferences.display == .used ? used : 100 - used) / 100)
            }
        }.frame(height: 5)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(provider.rawValue) allowance")
            .accessibilityValue("\(store.preferences.display.percentage(used)) percent \(store.preferences.display.title.lowercased())\(fresh ? "" : ", last known")")
    }
}
