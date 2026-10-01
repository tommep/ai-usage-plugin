import Foundation
import SwiftUI

enum WindowChoice: String, CaseIterable, Identifiable {
    case short, weekly
    var id: String { rawValue }
    var title: String { self == .short ? "Short window" : "Weekly" }
}

enum DisplayMode: String, CaseIterable, Identifiable {
    case used, remaining
    var id: String { rawValue }
    var title: String { self == .used ? "Used" : "Remaining" }
    func percentage(_ used: Double) -> Int { Int((self == .used ? used : 100 - used).rounded()) }
}

enum ProviderLabelStyle: String, CaseIterable, Identifiable {
    case letters, icons, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .letters: return "Letters"
        case .icons: return "Icons"
        case .both: return "Both"
        }
    }
    var showsIcons: Bool { self != .letters }
    var showsLetters: Bool { self != .icons }
}

@MainActor
final class Preferences: ObservableObject {
    @Published var choices: [Provider: WindowChoice] { didSet { save(); onChange?() } }
    @Published var display: DisplayMode { didSet { defaults.set(display.rawValue, forKey: "displayMode"); onChange?() } }
    @Published var providerLabels: ProviderLabelStyle { didSet { defaults.set(providerLabels.rawValue, forKey: "providerLabels"); onChange?() } }
    var onChange: (() -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        display = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .used
        providerLabels = ProviderLabelStyle(rawValue: defaults.string(forKey: "providerLabels") ?? "") ?? .letters
        let legacy = defaults.object(forKey: "weekly").map { _ in defaults.bool(forKey: "weekly") ? WindowChoice.weekly : .short }
        choices = Dictionary(uniqueKeysWithValues: Provider.allCases.map { provider in
            let choice = WindowChoice(rawValue: defaults.string(forKey: "window.\(provider.rawValue)") ?? "")
            return (provider, choice ?? legacy ?? (provider == .codex ? .weekly : .short))
        })
    }

    func choice(_ provider: Provider) -> WindowChoice { choices[provider] ?? .short }
    private func save() {
        for (provider, choice) in choices { defaults.set(choice.rawValue, forKey: "window.\(provider.rawValue)") }
    }
}
