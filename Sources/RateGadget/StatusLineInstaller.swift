import Foundation

/// Wires up Claude Code's `statusLine` feature (in `~/.claude/settings.json`) to
/// call our bridge script, so the rate_limits it reports get mirrored into the
/// shared file `ClaudeRateLimitWatcher` reads. Never overwrites an existing
/// user-configured statusLine.
enum StatusLineInstaller {
    struct InstallResult {
        var installed: Bool
        var message: String
    }

    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RateGadget")
    // Claude Code executes the statusLine command via /bin/sh without quoting,
    // so the script must live at a path with no spaces (NOT Application Support).
    static let scriptDestination = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/rate-gadget-statusline.sh")
    /// Older installs placed the script under Application Support; the space in
    /// that path breaks Claude Code's sh invocation, so migrate away from it.
    private static let legacyScriptPath = supportDir.appendingPathComponent("claude-statusline.sh").path

    static func ensureInstalled() -> InstallResult {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")

        do {
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            try installScript()
        } catch {
            return InstallResult(installed: false, message: "スクリプトの配置に失敗しました: \(error.localizedDescription)")
        }

        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // No settings.json yet, or unreadable — create a minimal one.
            let settings: [String: Any] = [
                "statusLine": statusLineValue()
            ]
            do {
                try write(settings: settings, to: settingsURL)
                return InstallResult(installed: true, message: "settings.json を新規作成し statusLine を設定しました")
            } catch {
                return InstallResult(installed: false, message: "settings.json の作成に失敗しました: \(error.localizedDescription)")
            }
        }

        if let existing = settings["statusLine"] as? [String: Any],
           let command = existing["command"] as? String {
            if command == scriptDestination.path {
                return InstallResult(installed: true, message: "statusLine は設定済みです")
            }
            if command != legacyScriptPath {
                return InstallResult(
                    installed: false,
                    message: "既存の statusLine 設定を検出したため変更していません。\(scriptDestination.path) を手動で組み込んでください。"
                )
            }
            // Ours, but at the broken legacy path — fall through and rewrite.
        } else if settings["statusLine"] != nil {
            return InstallResult(
                installed: false,
                message: "既存の statusLine 設定を検出したため変更していません。\(scriptDestination.path) を手動で組み込んでください。"
            )
        }

        do {
            try backup(settingsURL: settingsURL, data: data)
            settings["statusLine"] = statusLineValue()
            try write(settings: settings, to: settingsURL)
            try? FileManager.default.removeItem(atPath: legacyScriptPath)
            return InstallResult(installed: true, message: "settings.json に statusLine を設定しました")
        } catch {
            return InstallResult(installed: false, message: "settings.json の更新に失敗しました: \(error.localizedDescription)")
        }
    }

    private static func statusLineValue() -> [String: Any] {
        ["type": "command", "command": scriptDestination.path]
    }

    private static func installScript() throws {
        let bundledScript = Bundle.main.url(forResource: "claude-statusline", withExtension: "sh")
        guard let bundledScript else {
            throw InstallerError.missingBundledScript
        }
        let data = try Data(contentsOf: bundledScript)
        try data.write(to: scriptDestination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptDestination.path)
    }

    private static func backup(settingsURL: URL, data: Data) throws {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-\(timestamp)")
        try data.write(to: backupURL)
    }

    private static func write(settings: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    enum InstallerError: LocalizedError {
        case missingBundledScript
        var errorDescription: String? {
            switch self {
            case .missingBundledScript: return "claude-statusline.sh がバンドルに見つかりません"
            }
        }
    }
}
