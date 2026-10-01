import Foundation

struct UsageAlert: Equatable {
    enum Kind: Equatable { case threshold(Int), reset }
    let provider: Provider
    let window: UsageWindow
    let kind: Kind
    var identifier: String {
        let suffix: String
        switch kind { case .threshold(let value): suffix = "\(value)"; case .reset: suffix = "reset" }
        let reset = window.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
        return "\(provider.rawValue).\(window.id).\(reset).\(suffix)"
    }
}

// Track observed transitions, never infer a renewed allowance from the clock alone.
struct UsageAlertTracker {
    private struct WindowState: Codable {
        let reset: Date
        let observed: Date
        let used: Double
        var announced: Set<Int>
    }
    private var states: [String: [String: WindowState]] = [:]
    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: "alertWindowStates"), let stored = try? JSONDecoder().decode([String: [String: WindowState]].self, from: data) { states = stored }
    }

    mutating func clear(_ provider: Provider? = nil) {
        if let provider { states.removeValue(forKey: provider.rawValue) } else { states.removeAll() }
        persist()
    }

    mutating func observe(_ snapshot: UsageSnapshot, provider: Provider, now: Date) -> [UsageAlert] {
        guard snapshot.isFresh(at: now), snapshot.observedAt <= now else { return [] }
        var events: [UsageAlert] = []
        for window in snapshot.windows where window.active(at: now) {
            // Without a reset timestamp we cannot identify a quota window or renewal.
            guard let reset = window.resetsAt else { continue }
            let previous = states[provider.rawValue]?[window.id]
            if let previous, snapshot.observedAt <= previous.observed { continue }
            let sameWindow = previous?.reset == reset
            var announced = sameWindow ? previous!.announced : Set<Int>()
            // Opening/enabling alerts establishes a quiet baseline rather than a flood.
            if previous == nil { announced = Set([80, 95].filter { window.used >= Double($0) }) }
            else if sameWindow {
                let crossed = [80, 95].filter { previous!.used < Double($0) && window.used >= Double($0) && !announced.contains($0) }
                if let highest = crossed.last {
                    events.append(UsageAlert(provider: provider, window: window, kind: .threshold(highest)))
                    announced.formUnion(crossed)
                }
            } else {
                if previous!.used >= 100, window.used < 100, reset > previous!.reset {
                    events.append(UsageAlert(provider: provider, window: window, kind: .reset))
                }
                announced = Set([80, 95].filter { window.used >= Double($0) })
            }
            states[provider.rawValue, default: [:]][window.id] = WindowState(reset: reset, observed: snapshot.observedAt, used: window.used, announced: announced)
        }
        persist()
        return events
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(states) { defaults?.set(data, forKey: "alertWindowStates") }
    }
}
