import Foundation

enum Provider: String, CaseIterable, Identifiable {
    case codex = "Codex", claude = "Claude"
    var id: String { rawValue }
}

struct UsageWindow: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let used: Double
    let resetsAt: Date
    let minutes: Int

    func active(at now: Date) -> Bool { resetsAt > now }
    func countdown(at now: Date) -> String {
        let seconds = max(0, Int(resetsAt.timeIntervalSince(now)))
        if seconds == 0 { return "Refreshing reset…" }
        if seconds >= 86400 { return "\(seconds / 86400)d \((seconds % 86400) / 3600)h" }
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        return "\(max(1, seconds / 60))m"
    }
}

struct UsageSnapshot: Codable {
    let windows: [UsageWindow]
    let observedAt: Date
    let plan: String?
    func isFresh(at now: Date) -> Bool { now.timeIntervalSince(observedAt) < 600 }
    func featured(weekly: Bool, at now: Date) -> UsageWindow? {
        let active = windows.filter { $0.active(at: now) }
        return (weekly ? active.max { $0.minutes < $1.minutes } : active.min { $0.minutes < $1.minutes })
    }
}

enum UsageFailure: Error, LocalizedError {
    case signIn, missingCLI, unavailable, timeout, throttled, invalidData
    var errorDescription: String? {
        switch self {
        case .signIn: return "Sign in to continue"
        case .missingCLI: return "Install the provider’s command line app"
        case .timeout: return "Refresh timed out. Try again."
        case .throttled: return "Provider is limiting refreshes. Trying again later."
        case .invalidData: return "Usage data is unavailable for this account"
        case .unavailable: return "Couldn’t reach your usage. Try again."
        }
    }
}

enum UsageParser {
    static func codex(_ data: Data, at date: Date) throws -> UsageSnapshot {
        let reply = try JSONDecoder().decode(CodexReply.self, from: data)
        guard let bucket = reply.result?.rateLimitsByLimitId?["codex"] ?? reply.result?.rateLimits,
              bucket.limitId == nil || bucket.limitId == "codex" else { throw UsageFailure.invalidData }
        let windows = try [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { key, window -> UsageWindow? in
            guard let window else { return nil }
            guard valid(window.usedPercent), let reset = window.resetsAt, window.windowDurationMins > 0 else { throw UsageFailure.invalidData }
            let mins = window.windowDurationMins
            let title = mins >= 10080 ? "Weekly" : mins == 300 ? "5-hour" : "\(mins / 60 > 0 ? "\(mins / 60)-hour" : "\(mins)-minute")"
            return UsageWindow(id: key, title: title, used: window.usedPercent, resetsAt: Date(timeIntervalSince1970: reset), minutes: mins)
        }
        guard !windows.isEmpty else { throw UsageFailure.invalidData }
        return UsageSnapshot(windows: windows, observedAt: date, plan: bucket.planType)
    }

    static func claude(_ data: Data, at date: Date) throws -> UsageSnapshot {
        let reply = try JSONDecoder().decode(ClaudeReply.self, from: data)
        let windows = try [("five_hour", "5-hour", 300, reply.five_hour), ("seven_day", "Weekly", 10080, reply.seven_day)].compactMap { key, title, mins, window -> UsageWindow? in
            guard let window else { return nil }
            guard let used = window.utilization, valid(used), let value = window.resets_at, let reset = parseDate(value) else { throw UsageFailure.invalidData }
            return UsageWindow(id: key, title: title, used: used, resetsAt: reset, minutes: mins)
        }
        guard !windows.isEmpty else { throw UsageFailure.invalidData }
        return UsageSnapshot(windows: windows, observedAt: date, plan: nil)
    }

    static func valid(_ percent: Double) -> Bool { percent.isFinite && (0...100).contains(percent) }
    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

private struct CodexReply: Decodable { let result: CodexResult? }
private struct CodexResult: Decodable { let rateLimits: CodexBucket?; let rateLimitsByLimitId: [String: CodexBucket]? }
private struct CodexBucket: Decodable {
    let limitId: String?; let primary: CodexWindow?; let secondary: CodexWindow?; let planType: String?
}
private struct CodexWindow: Decodable { let usedPercent: Double; let windowDurationMins: Int; let resetsAt: Double? }
private struct ClaudeReply: Decodable { let five_hour: ClaudeWindow?; let seven_day: ClaudeWindow? }
private struct ClaudeWindow: Decodable { let utilization: Double?; let resets_at: String? }
