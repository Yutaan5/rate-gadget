import Foundation

/// Installs and removes RateGadget's Claude Code statusLine integration.
/// Existing third-party status lines are never replaced, and malformed settings
/// are never rewritten.
enum StatusLineInstaller {
    struct InstallResult {
        var installed: Bool
        var message: String
    }

    private static let shellResourceName = "claude-statusline"
    private static let bridgeResourceName = "claude-statusline"

    static var supportDir: URL {
        supportDirectory(in: FileManager.default.homeDirectoryForCurrentUser)
    }

    static var scriptDestination: URL {
        shellDestination(in: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func ensureInstalled() -> InstallResult {
        guard let shellURL = Bundle.main.url(forResource: shellResourceName, withExtension: "sh"),
              let bridgeURL = Bundle.main.url(forResource: bridgeResourceName, withExtension: "js") else {
            return InstallResult(installed: false, message: "Claude連携スクリプトがアプリ内に見つかりません")
        }

        do {
            return try ensureInstalled(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                shellScriptData: Data(contentsOf: shellURL),
                bridgeScriptData: Data(contentsOf: bridgeURL)
            )
        } catch {
            return InstallResult(installed: false, message: "Claude連携の設定に失敗しました: \(error.localizedDescription)")
        }
    }

    static func uninstall() -> InstallResult {
        do {
            return try uninstall(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
        } catch {
            return InstallResult(installed: true, message: "Claude連携の解除に失敗しました: \(error.localizedDescription)")
        }
    }

    /// Internal entry point used by tests with an isolated home directory.
    static func ensureInstalled(
        homeDirectory: URL,
        shellScriptData: Data,
        bridgeScriptData: Data
    ) throws -> InstallResult {
        let fileManager = FileManager.default
        let claudeDirectory = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let settingsFileExists = fileManager.fileExists(atPath: settingsURL.path)

        var originalData: Data?
        var settings: [String: Any] = [:]
        if settingsFileExists {
            do {
                let data = try Data(contentsOf: settingsURL)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return InstallResult(
                        installed: false,
                        message: "settings.json の形式が不正なため変更していません"
                    )
                }
                originalData = data
                settings = object
            } catch {
                return InstallResult(
                    installed: false,
                    message: "settings.json を読み取れないため変更していません: \(error.localizedDescription)"
                )
            }
        }

        try fileManager.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let supportDirectory = supportDirectory(in: homeDirectory)
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)

        try shellScriptData.write(to: shellDestination(in: homeDirectory), options: .atomic)
        try bridgeScriptData.write(to: bridgeDestination(in: homeDirectory), options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: shellDestination(in: homeDirectory).path
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: bridgeDestination(in: homeDirectory).path
        )
        removeLegacyDebugPayload(in: homeDirectory)

        let desiredCommand = statusLineCommand(in: homeDirectory)
        if let existing = settings["statusLine"] as? [String: Any],
           let command = existing["command"] as? String {
            if command == desiredCommand {
                return InstallResult(installed: true, message: "statusLine は設定済みです")
            }
            guard ownedCommands(in: homeDirectory).contains(command) else {
                return InstallResult(
                    installed: false,
                    message: "既存の statusLine 設定は変更していません。必要なら \(desiredCommand) を手動で組み込んでください。"
                )
            }
            // An older RateGadget command is safe to migrate.
        } else if settings["statusLine"] != nil {
            return InstallResult(
                installed: false,
                message: "既存の statusLine 設定は変更していません。必要なら \(desiredCommand) を手動で組み込んでください。"
            )
        }

        if let originalData {
            try backup(settingsURL: settingsURL, data: originalData)
        }
        settings["statusLine"] = statusLineValue(in: homeDirectory)
        try write(settings: settings, to: settingsURL)
        removeLegacyScript(in: homeDirectory)
        return InstallResult(
            installed: true,
            message: settingsFileExists
                ? "settings.json に statusLine を設定しました"
                : "settings.json を新規作成し statusLine を設定しました"
        )
    }

    /// Removes only a statusLine command owned by RateGadget. If settings are
    /// malformed, keep the scripts in place so Claude Code is not left pointing
    /// at a missing command.
    static func uninstall(homeDirectory: URL) throws -> InstallResult {
        let fileManager = FileManager.default
        let settingsURL = homeDirectory.appendingPathComponent(".claude/settings.json")

        if fileManager.fileExists(atPath: settingsURL.path) {
            let data: Data
            let object: Any
            do {
                data = try Data(contentsOf: settingsURL)
                object = try JSONSerialization.jsonObject(with: data)
            } catch {
                return InstallResult(
                    installed: true,
                    message: "settings.json を読み取れないためClaude連携を解除していません: \(error.localizedDescription)"
                )
            }
            guard var settings = object as? [String: Any] else {
                return InstallResult(
                    installed: true,
                    message: "settings.json の形式が不正なためClaude連携を解除していません"
                )
            }

            if let existing = settings["statusLine"] as? [String: Any],
               let command = existing["command"] as? String,
               ownedCommands(in: homeDirectory).contains(command) {
                try backup(settingsURL: settingsURL, data: data)
                settings.removeValue(forKey: "statusLine")
                try write(settings: settings, to: settingsURL)
            }
        }

        removeArtifacts(in: homeDirectory)
        return InstallResult(installed: false, message: "Claude連携を解除しました")
    }

    static func statusLineCommand(in homeDirectory: URL) -> String {
        shellQuote(shellDestination(in: homeDirectory).path)
    }

    private static func statusLineValue(in homeDirectory: URL) -> [String: Any] {
        ["type": "command", "command": statusLineCommand(in: homeDirectory)]
    }

    private static func ownedCommands(in homeDirectory: URL) -> Set<String> {
        let shellPath = shellDestination(in: homeDirectory).path
        return [
            shellPath,
            shellQuote(shellPath),
            supportDirectory(in: homeDirectory).appendingPathComponent("claude-statusline.sh").path,
        ]
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func supportDirectory(in homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support/RateGadget", isDirectory: true)
    }

    private static func shellDestination(in homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".claude/rate-gadget-statusline.sh")
    }

    private static func bridgeDestination(in homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".claude/rate-gadget-statusline.js")
    }

    private static func backup(settingsURL: URL, data: Data) throws {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let suffix = UUID().uuidString.prefix(8)
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-\(timestamp)-\(suffix)")
        try data.write(to: backupURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
    }

    private static func write(settings: [String: Any], to url: URL) throws {
        let fileManager = FileManager.default
        let existingPermissions = (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions])
            ?? NSNumber(value: 0o600)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: existingPermissions], ofItemAtPath: url.path)
    }

    private static func removeArtifacts(in homeDirectory: URL) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: shellDestination(in: homeDirectory))
        try? fileManager.removeItem(at: bridgeDestination(in: homeDirectory))
        removeLegacyScript(in: homeDirectory)
        let supportDirectory = supportDirectory(in: homeDirectory)
        try? fileManager.removeItem(at: supportDirectory.appendingPathComponent("claude-rate.json"))
        try? fileManager.removeItem(at: supportDirectory.appendingPathComponent("claude-statusline-last-input.json"))
    }

    private static func removeLegacyScript(in homeDirectory: URL) {
        try? FileManager.default.removeItem(
            at: supportDirectory(in: homeDirectory).appendingPathComponent("claude-statusline.sh")
        )
    }

    private static func removeLegacyDebugPayload(in homeDirectory: URL) {
        try? FileManager.default.removeItem(
            at: supportDirectory(in: homeDirectory).appendingPathComponent("claude-statusline-last-input.json")
        )
    }
}
