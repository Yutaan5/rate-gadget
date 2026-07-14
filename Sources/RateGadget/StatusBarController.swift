import AppKit
import ServiceManagement

/// Owns the NSStatusItem, the two data sources, and renders both the compact
/// menu bar icon and the dropdown detail menu. Each source (Claude / Codex)
/// can be hidden via the menu; a hidden source is fully stopped, not just
/// undrawn, so Claude-only users never spawn a codex subprocess.
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 50)
    private let menu = NSMenu()
    private let codexPoller = CodexRateLimitPoller()
    private let claudeWatcher = ClaudeRateLimitWatcher()

    private var claudeSnapshot: ClaudeRateSnapshot?
    private var codexSnapshot: CodexRateSnapshot?
    private var codexErrorMessage: String?
    private var statusLineMessage: String?

    override init() {
        super.init()

        menu.delegate = self
        statusItem.menu = menu

        codexPoller.onUpdate = { [weak self] snapshot in
            self?.codexSnapshot = snapshot
            self?.codexErrorMessage = nil
            self?.refreshIcon()
        }
        codexPoller.onError = { [weak self] message in
            self?.codexErrorMessage = message
            self?.refreshIcon()
        }
        claudeWatcher.onUpdate = { [weak self] snapshot in
            self?.claudeSnapshot = snapshot
            self?.refreshIcon()
        }

        if Preferences.showClaude {
            startClaude()
        }
        if Preferences.showCodex {
            codexPoller.start()
        }
        refreshIcon()
    }

    private func startClaude() {
        let installResult = StatusLineInstaller.ensureInstalled()
        statusLineMessage = installResult.installed ? nil : installResult.message
        NSLog("[RateGadget] statusLine install: %@", installResult.message)
        claudeWatcher.start()
    }

    private func refreshIcon() {
        var entries: [MenuBarIconRenderer.Entry] = []
        if Preferences.showClaude {
            entries.append(.init(label: "C", window: claudeSnapshot?.headline))
        }
        if Preferences.showCodex {
            entries.append(.init(label: "X", window: codexSnapshot?.headline))
        }
        statusItem.length = MenuBarIconRenderer.iconWidth(entryCount: entries.count) + 4
        statusItem.button?.image = MenuBarIconRenderer.render(entries: entries)
    }

    /// Rebuilds the menu contents each time it is about to open, so the data
    /// rows are always current without touching the menu while it's tracking.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        buildMenu(into: menu)
    }

    private func buildMenu(into menu: NSMenu) {

        if Preferences.showClaude {
            menu.addItem(sectionHeader("Claude"))
            menu.addItem(rowItem(.init(
                label: "5時間",
                window: claudeSnapshot?.fiveHour,
                note: formatResetsAt(claudeSnapshot?.fiveHour?.resetsAt)
            )))
            menu.addItem(rowItem(.init(
                label: "週次",
                window: claudeSnapshot?.sevenDay,
                note: formatResetsAt(claudeSnapshot?.sevenDay?.resetsAt)
            )))
            if let snapshot = claudeSnapshot {
                let staleness = formatStaleness(snapshot.stalenessInterval)
                let text = snapshot.isStale
                    ? "⚠️ 最終更新 \(staleness)（セッション非アクティブ）"
                    : "最終更新 \(staleness)"
                menu.addItem(infoItem(text))
            } else {
                menu.addItem(infoItem("まだデータがありません（claudeを開いて1往復送ると反映されます）"))
            }
            if let message = statusLineMessage {
                menu.addItem(infoItem("⚠️ \(message)"))
            }
        }

        if Preferences.showClaude && Preferences.showCodex {
            menu.addItem(.separator())
        }

        if Preferences.showCodex {
            menu.addItem(sectionHeader("Codex"))
            menu.addItem(rowItem(.init(
                label: codexSnapshot?.primary?.durationLabel ?? "primary",
                window: codexSnapshot?.primary,
                note: formatResetsAt(codexSnapshot?.primary?.resetsAt)
            )))
            if let secondary = codexSnapshot?.secondary {
                menu.addItem(rowItem(.init(
                    label: secondary.durationLabel ?? "secondary",
                    window: secondary,
                    note: formatResetsAt(secondary.resetsAt)
                )))
            }
            if let plan = codexSnapshot?.planType {
                menu.addItem(infoItem("プラン: \(plan)"))
            }
            if let error = codexErrorMessage {
                menu.addItem(infoItem("⚠️ \(error)"))
            }
        }

        if Preferences.showClaude || Preferences.showCodex {
            menu.addItem(.separator())
        }

        let claudeToggleView = ToggleRowView(title: "Claude を表示", isOn: Preferences.showClaude)
        claudeToggleView.onChange = { [weak self] isOn in
            self?.setClaudeVisible(isOn)
        }
        let claudeToggle = NSMenuItem()
        claudeToggle.view = claudeToggleView
        menu.addItem(claudeToggle)

        let codexToggleView = ToggleRowView(title: "Codex を表示", isOn: Preferences.showCodex)
        codexToggleView.onChange = { [weak self] isOn in
            self?.setCodexVisible(isOn)
        }
        let codexToggle = NSMenuItem()
        codexToggle.view = codexToggleView
        menu.addItem(codexToggle)

        menu.addItem(.separator())

        if Preferences.showCodex {
            let refreshItem = NSMenuItem(title: "今すぐ更新 (Codex)", action: #selector(refreshCodex), keyEquivalent: "")
            refreshItem.target = self
            menu.addItem(refreshItem)
        }

        let loginItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLoginItemEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]
        )
        return item
    }

    private func infoItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return item
    }

    private func rowItem(_ content: DetailRowView.Content) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = DetailRowView(content: content)
        return item
    }

    private func setClaudeVisible(_ visible: Bool) {
        Preferences.showClaude = visible
        if visible {
            startClaude()
        } else {
            claudeWatcher.stop()
            claudeSnapshot = nil
            statusLineMessage = nil
        }
        // Only the icon updates immediately; the open menu's data sections
        // reflect the change the next time it opens (menuNeedsUpdate).
        refreshIcon()
    }

    private func setCodexVisible(_ visible: Bool) {
        Preferences.showCodex = visible
        if visible {
            codexPoller.start()
        } else {
            codexPoller.stop()
            codexSnapshot = nil
            codexErrorMessage = nil
        }
        refreshIcon()
    }

    @objc private func refreshCodex() {
        codexPoller.refreshNow()
    }

    private var isLoginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("[RateGadget] login item toggle failed: %@", error.localizedDescription)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
