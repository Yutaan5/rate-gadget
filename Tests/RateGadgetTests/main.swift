import Foundation
@testable import RateGadgetCore

private var failures = 0

private func check(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message) (\(file):\(line))\n", stderr)
    }
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw TestError.requirementFailed(message) }
    return value
}

private func testModels() throws {
    check(RateWindow(usedPercent: 49, resetsAt: nil, windowDurationMins: nil).severity == .ok,
          "49% should be OK")
    check(RateWindow(usedPercent: 50, resetsAt: nil, windowDurationMins: nil).severity == .warn,
          "50% should be warning")
    check(RateWindow(usedPercent: 80, resetsAt: nil, windowDurationMins: nil).severity == .critical,
          "80% should be critical")
    check(RateWindow(usedPercent: 0, resetsAt: nil, windowDurationMins: 300).durationLabel == "5h",
          "300 minutes should be 5h")
    check(RateWindow(usedPercent: 0, resetsAt: nil, windowDurationMins: 10_080).durationLabel == "7d",
          "10080 minutes should be 7d")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try require(TimeZone(identifier: "Asia/Tokyo"), "Tokyo time zone")
    let now = try require(calendar.date(from: DateComponents(
        year: 2026, month: 7, day: 20, hour: 23, minute: 30
    )), "now date")
    let reset = try require(calendar.date(from: DateComponents(
        year: 2026, month: 7, day: 21, hour: 1
    )), "reset date")
    check(formatResetsAt(reset, now: now, calendar: calendar) == "明日 01:00",
          "a reset after midnight must be tomorrow")
    check(formatResetsAt(now.addingTimeInterval(-1), now: now) == "時刻経過",
          "past reset should be explicit")
    check(formatStaleness(-10) == "たった今", "future timestamp should be clamped")
    check(formatStaleness(25 * 60 * 60) == "1日前", "long staleness should use days")
}

private func testParsing() throws {
    let snapshot = try require(CodexRateLimitPoller.parseSnapshot(from: [
        "rateLimits": [
            "planType": "plus",
            "primary": [
                "usedPercent": 42,
                "windowDurationMins": 300,
                "resetsAt": 1_800_000_000,
            ],
            "secondary": NSNull(),
        ]
    ]), "current Codex response should parse")
    check(snapshot.primary?.usedPercent == 42, "Codex percentage")
    check(snapshot.primary?.durationLabel == "5h", "Codex duration")
    check(snapshot.planType == "plus", "Codex plan")
    check(CodexRateLimitPoller.parseSnapshot(from: [
        "rateLimits": ["planType": "plus"]
    ]) == nil, "Codex response without windows should fail")

    let window = try require(ClaudeRateLimitWatcher.parseWindow([
        "used_percentage": 12.6,
        "resets_at": 1_800_000_000.5,
    ]), "fractional Claude percentage should parse")
    check(window.usedPercent == 13, "Claude percentage should round")
    check(window.resetsAt?.timeIntervalSince1970 == 1_800_000_000.5, "Claude reset timestamp")
}

private func testInstaller() throws {
    let shellData = Data("#!/bin/sh\n".utf8)
    let bridgeData = Data("function run() {}\n".utf8)

    do {
        let temporary = try makeTemporaryHome(name: "Home With Space")
        defer { try? FileManager.default.removeItem(at: temporary.root) }
        let supportDirectory = temporary.home
            .appendingPathComponent("Library/Application Support/RateGadget", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let legacyDebugPayload = supportDirectory.appendingPathComponent("claude-statusline-last-input.json")
        try Data("private input".utf8).write(to: legacyDebugPayload)
        let result = try StatusLineInstaller.ensureInstalled(
            homeDirectory: temporary.home,
            shellScriptData: shellData,
            bridgeScriptData: bridgeData
        )
        check(result.installed, "fresh install")
        let settings = try readSettings(temporary.home)
        let statusLine = try require(settings["statusLine"] as? [String: Any], "statusLine object")
        check(statusLine["command"] as? String == StatusLineInstaller.statusLineCommand(in: temporary.home),
              "command should be shell-quoted")
        check(FileManager.default.isExecutableFile(
            atPath: temporary.home.appendingPathComponent(".claude/rate-gadget-statusline.sh").path
        ), "installed shell should be executable")
        check(!FileManager.default.fileExists(atPath: legacyDebugPayload.path),
              "install should remove the legacy private debug payload")
        let supportPermissions = try FileManager.default.attributesOfItem(atPath: supportDirectory.path)[.posixPermissions]
            as? NSNumber
        check(supportPermissions?.intValue == 0o700, "support directory should be private")
    }

    do {
        let temporary = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: temporary.root) }
        let claudeDirectory = temporary.home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let malformed = Data("{not-json".utf8)
        try malformed.write(to: settingsURL)
        let result = try StatusLineInstaller.ensureInstalled(
            homeDirectory: temporary.home,
            shellScriptData: shellData,
            bridgeScriptData: bridgeData
        )
        check(!result.installed, "malformed settings should block install")
        let dataAfterInstall = try Data(contentsOf: settingsURL)
        check(dataAfterInstall == malformed, "malformed settings must be untouched")
    }

    do {
        let temporary = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: temporary.root) }
        try writeSettings(["theme": "dark", "statusLine": [
            "type": "command", "command": "third-party-status"
        ]], home: temporary.home)
        let result = try StatusLineInstaller.ensureInstalled(
            homeDirectory: temporary.home,
            shellScriptData: shellData,
            bridgeScriptData: bridgeData
        )
        let settings = try readSettings(temporary.home)
        check(!result.installed, "third-party status line should block automatic install")
        check((settings["statusLine"] as? [String: Any])?["command"] as? String == "third-party-status",
              "third-party status line must be preserved")
        check(settings["theme"] as? String == "dark", "unrelated settings must be preserved")
    }

    do {
        let temporary = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: temporary.root) }
        _ = try StatusLineInstaller.ensureInstalled(
            homeDirectory: temporary.home,
            shellScriptData: shellData,
            bridgeScriptData: bridgeData
        )
        var settings = try readSettings(temporary.home)
        settings["theme"] = "dark"
        try writeSettings(settings, home: temporary.home)
        let result = try StatusLineInstaller.uninstall(homeDirectory: temporary.home)
        settings = try readSettings(temporary.home)
        check(!result.installed, "uninstall result")
        check(settings["statusLine"] == nil, "owned statusLine should be removed")
        check(settings["theme"] as? String == "dark", "uninstall should preserve unrelated settings")
        check(!FileManager.default.fileExists(
            atPath: temporary.home.appendingPathComponent(".claude/rate-gadget-statusline.sh").path
        ), "uninstall should remove owned script")
    }

    do {
        let temporary = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: temporary.root) }
        let claudeDirectory = temporary.home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let malformed = Data("[invalid".utf8)
        try malformed.write(to: settingsURL)
        let result = try StatusLineInstaller.uninstall(homeDirectory: temporary.home)
        check(result.installed, "malformed settings should conservatively block uninstall")
        let dataAfterUninstall = try Data(contentsOf: settingsURL)
        check(dataAfterUninstall == malformed, "failed uninstall must leave malformed settings untouched")
    }
}

private struct TemporaryHome {
    let root: URL
    let home: URL
}

private func makeTemporaryHome(name: String = UUID().uuidString) throws -> TemporaryHome {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RateGadgetTests-\(UUID().uuidString)", isDirectory: true)
    let home = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return TemporaryHome(root: root, home: home)
}

private func readSettings(_ home: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
    return try require(JSONSerialization.jsonObject(with: data) as? [String: Any], "settings object")
}

private func writeSettings(_ settings: [String: Any], home: URL) throws {
    let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: settings)
    try data.write(to: claudeDirectory.appendingPathComponent("settings.json"))
}

private enum TestError: Error {
    case requirementFailed(String)
}

do {
    try testModels()
    try testParsing()
    try testInstaller()
} catch {
    failures += 1
    fputs("FAIL: unexpected error: \(error)\n", stderr)
}

if failures > 0 {
    fputs("\(failures) test(s) failed\n", stderr)
    exit(1)
}
print("All RateGadget tests passed")
