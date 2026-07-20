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

enum Severity: Equatable {
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

    /// A healthy poll happens once a minute. Treat three missed polls as stale
    /// so a hung app-server can never leave an apparently-current gauge behind.
    static let staleThreshold: TimeInterval = 3 * 60
    var stalenessInterval: TimeInterval { Date().timeIntervalSince(updatedAt) }
    var isStale: Bool { stalenessInterval > Self.staleThreshold }
}

func formatPercent(_ value: Int?) -> String {
    guard let value else { return "--" }
    return "\(value)%"
}

func formatResetsAt(
    _ date: Date?,
    now: Date = Date(),
    calendar: Calendar = .current
) -> String {
    guard let date else { return "-" }
    if date <= now { return "時刻経過" }

    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "ja_JP")
    formatter.timeZone = calendar.timeZone

    if calendar.isDate(date, inSameDayAs: now) {
        formatter.dateFormat = "HH:mm"
        return "今日 \(formatter.string(from: date))"
    }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
       calendar.isDate(date, inSameDayAs: tomorrow) {
        formatter.dateFormat = "HH:mm"
        return "明日 \(formatter.string(from: date))"
    }

    formatter.dateFormat = "M/d HH:mm"
    return formatter.string(from: date)
}

func formatStaleness(_ interval: TimeInterval) -> String {
    let safeInterval = max(0, interval)
    if safeInterval < 60 { return "たった今" }
    let minutes = Int(safeInterval / 60)
    if minutes < 60 { return "\(minutes)分前" }
    let hours = minutes / 60
    if hours >= 24 { return "\(hours / 24)日前" }
    return "\(hours)時間前"
}
