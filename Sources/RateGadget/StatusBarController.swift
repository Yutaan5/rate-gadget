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

    // Gauge rows of the currently built menu, kept so data arriving while the
    // menu is open (e.g. after tapping the refresh button) updates in place.
    private var claudeFiveRow: DetailRowView?
    private var claudeSevenRow: DetailRowView?
    private var codexPrimaryRow: DetailRowView?
    private var codexSecondaryRow: DetailRowView?

    override init() {
        super.init()

        menu.delegate = self
        statusItem.menu = menu

        codexPoller.onUpdate = { [weak self] snapshot in
            self?.codexSnapshot = snapshot
            self?.codexErrorMessage = nil
            self?.refreshIcon()
            self?.updateOpenMenuRows()
        }
        codexPoller.onError = { [weak self] message in
            self?.codexErrorMessage = message
            self?.refreshIcon()
        }
        claudeWatcher.onUpdate = { [weak self] snapshot in
            self?.claudeSnapshot = snapshot
            self?.refreshIcon()
            self?.updateOpenMenuRows()
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
        claudeFiveRow = nil
        claudeSevenRow = nil
        codexPrimaryRow = nil
        codexSecondaryRow = nil

        if Preferences.showClaude {
            menu.addItem(headerItem(title: "Claude", showsRefresh: false, onRefresh: nil))
            claudeFiveRow = addRow(claudeFiveContent(), to: menu)
            claudeSevenRow = addRow(claudeSevenContent(), to: menu)
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
            menu.addItem(headerItem(title: "Codex", showsRefresh: true, onRefresh: { [weak self] in
                self?.codexPoller.refreshNow()
            }))
            codexPrimaryRow = addRow(codexPrimaryContent(), to: menu)
            if codexSnapshot?.secondary != nil {
                codexSecondaryRow = addRow(codexSecondaryContent(), to: menu)
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

        let loginItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLoginItemEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func claudeFiveContent() -> DetailRowView.Content {
        .init(
            label: "5時間",
            window: claudeSnapshot?.fiveHour,
            note: formatResetsAt(claudeSnapshot?.fiveHour?.resetsAt)
        )
    }

    private func claudeSevenContent() -> DetailRowView.Content {
        .init(
            label: "週次",
            window: claudeSnapshot?.sevenDay,
            note: formatResetsAt(claudeSnapshot?.sevenDay?.resetsAt)
        )
    }

    private func codexPrimaryContent() -> DetailRowView.Content {
        .init(
            label: codexSnapshot?.primary?.durationLabel ?? "primary",
            window: codexSnapshot?.primary,
            note: formatResetsAt(codexSnapshot?.primary?.resetsAt)
        )
    }

    private func codexSecondaryContent() -> DetailRowView.Content {
        .init(
            label: codexSnapshot?.secondary?.durationLabel ?? "secondary",
            window: codexSnapshot?.secondary,
            note: formatResetsAt(codexSnapshot?.secondary?.resetsAt)
        )
    }

    /// Pushes fresh snapshot data into the rows of the currently built menu,
    /// so an open menu updates in place (DetailRowView redraws on content set).
    private func updateOpenMenuRows() {
        claudeFiveRow?.content = claudeFiveContent()
        claudeSevenRow?.content = claudeSevenContent()
        codexPrimaryRow?.content = codexPrimaryContent()
        codexSecondaryRow?.content = codexSecondaryContent()
    }

    private func headerItem(title: String, showsRefresh: Bool, onRefresh: (() -> Void)?) -> NSMenuItem {
        let view = SectionHeaderRowView(title: title, showsRefresh: showsRefresh)
        view.onRefresh = onRefresh
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = view
        return item
    }

    private func addRow(_ content: DetailRowView.Content, to menu: NSMenu) -> DetailRowView {
        let view = DetailRowView(content: content)
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = view
        menu.addItem(item)
        return view
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
