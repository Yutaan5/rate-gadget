import Foundation

/// A single rate-limit window (e.g. "5 hour" or "7 day") as reported by a CLI.
struct RateWindow {
    /// 0...100
    var usedPercent: Int
    var resetsAt: Date?
    var windowDurationMins: Int?

    var severity: Severity {
        switch usedPercent {
        case ..<50: return .ok
        case 50..<80: return .warn
        default: return .critical
        }
    }

    /// Short human label derived from the window duration ("5h", "7d", ...).
    var durationLabel: String? {
        guard let mins = windowDurationMins else { return nil }
        if mins % (24 * 60) == 0 {
            return "\(mins / (24 * 60))d"
        }
        if mins % 60 == 0 {
            return "\(mins / 60)h"
        }
        return "\(mins)m"
    }
}

enum Severity {
    case ok
    case warn
    case critical
}

/// Latest known state from the Claude Code `statusLine` bridge file.
struct ClaudeRateSnapshot {
    var fiveHour: RateWindow?
    var sevenDay: RateWindow?
    /// When the bridge script last wrote this snapshot (i.e. last time a Claude Code
    /// TUI session was active and refreshed its status line).
    var updatedAt: Date

    /// The window we surface in the compact menu-bar view.
    var headline: RateWindow? { fiveHour ?? sevenDay }

    var stalenessInterval: TimeInterval { Date().timeIntervalSince(updatedAt) }

    static let staleThreshold: TimeInterval = 30 * 60
    var isStale: Bool { stalenessInterval > Self.staleThreshold }
}

/// Latest known state from `codex app-server`'s `account/rateLimits/read`.
struct CodexRateSnapshot {
    var primary: RateWindow?
    var secondary: RateWindow?
    var planType: String?
    var updatedAt: Date

    var headline: RateWindow? { primary ?? secondary }
}

func formatPercent(_ value: Int?) -> String {
    guard let value else { return "--" }
    return "\(value)%"
}

func formatResetsAt(_ date: Date?) -> String {
    guard let date else { return "-" }
    let now = Date()
    let interval = date.timeIntervalSince(now)
    if interval <= 0 { return "まもなく" }

    if interval < 24 * 60 * 60 {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "今日 \(formatter.string(from: date))"
    } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }
}

func formatStaleness(_ interval: TimeInterval) -> String {
    if interval < 60 { return "たった今" }
    let minutes = Int(interval / 60)
    if minutes < 60 { return "\(minutes)分前" }
    let hours = minutes / 60
    return "\(hours)時間前"
}
