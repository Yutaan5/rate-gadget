import Foundation

/// User-visible preferences, persisted via UserDefaults.
/// Claude-only users (common in-house) can hide the Codex gauge entirely —
/// hiding a source also stops its data collection (no codex subprocess, no
/// statusLine install).
enum Preferences {
    private static let showClaudeKey = "showClaude"
    private static let showCodexKey = "showCodex"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showClaudeKey: true,
            showCodexKey: true,
        ])
    }

    static var showClaude: Bool {
        get { UserDefaults.standard.bool(forKey: showClaudeKey) }
        set { UserDefaults.standard.set(newValue, forKey: showClaudeKey) }
    }

    static var showCodex: Bool {
        get { UserDefaults.standard.bool(forKey: showCodexKey) }
        set { UserDefaults.standard.set(newValue, forKey: showCodexKey) }
    }
}
