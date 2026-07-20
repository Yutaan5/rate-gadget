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
    private var claudeErrorMessage: String?
    private var codexSnapshot: CodexRateSnapshot?
    private var codexErrorMessage: String?
    private var statusLineMessage: String?
    private var generalMessage: String?
    private var freshnessTimer: Timer?
    private var appearanceObservation: NSKeyValueObservation?

    // Gauge rows of the currently built menu, kept so data arriving while the
    // menu is open (e.g. after tapping the refresh button) updates in place.
    private var claudeFiveRow: DetailRowView?
    private var claudeSevenRow: DetailRowView?
    private var codexPrimaryRow: DetailRowView?
    private var codexSecondaryRow: DetailRowView?

    private var menuIsOpen = false

    /// Which optional pieces the currently built menu contains. When incoming
    /// data changes one of these, an in-place row update isn't enough and the
    /// open menu is rebuilt.
    private struct MenuStructure: Equatable {
        var showClaude: Bool
        var showCodex: Bool
        var claudeHasData: Bool
        var claudeIsStale: Bool
        var codexHasData: Bool
        var codexIsStale: Bool
        var codexHasSecondary: Bool
        var codexPlanType: String?
        var codexErrorMessage: String?
        var claudeErrorMessage: String?
        var statusLineMessage: String?
        var generalMessage: String?
    }
    private var builtStructure: MenuStructure?

    private func currentStructure() -> MenuStructure {
        MenuStructure(
            showClaude: Preferences.showClaude,
            showCodex: Preferences.showCodex,
            claudeHasData: claudeSnapshot != nil,
            claudeIsStale: claudeSnapshot?.isStale ?? false,
            codexHasData: codexSnapshot != nil,
            codexIsStale: codexSnapshot?.isStale ?? false,
            codexHasSecondary: codexSnapshot?.secondary != nil,
            codexPlanType: codexSnapshot?.planType,
            codexErrorMessage: codexErrorMessage,
            claudeErrorMessage: claudeErrorMessage,
            statusLineMessage: statusLineMessage,
            generalMessage: generalMessage
        )
    }

    override init() {
        super.init()

        // With autoenablesItems (the default), view-based items that carry no
        // action get auto-disabled on menu.update(), and disabled items' views
        // never receive mouse events — which silently kills the toggle rows
        // and the refresh button. Manage enabled state explicitly instead.
        menu.autoenablesItems = false
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
            self?.updateOpenMenuRows()
        }
        claudeWatcher.onUpdate = { [weak self] snapshot in
            self?.claudeSnapshot = snapshot
            self?.claudeErrorMessage = nil
            self?.refreshIcon()
            self?.updateOpenMenuRows()
        }
        claudeWatcher.onError = { [weak self] message in
            self?.claudeErrorMessage = message
            self?.refreshIcon()
            self?.updateOpenMenuRows()
        }

        if Preferences.showClaude {
            startClaude()
        }
        if Preferences.showCodex {
            codexPoller.start()
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshForTimePassage()
        }
        timer.tolerance = 5
        freshnessTimer = timer
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshIcon()
            }
        }
        refreshIcon()
    }

    deinit {
        freshnessTimer?.invalidate()
        codexPoller.shutdown()
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
            let state: MenuBarIconRenderer.DataState
            if statusLineMessage != nil || claudeErrorMessage != nil {
                state = .error
            } else if let snapshot = claudeSnapshot {
                state = snapshot.isStale ? .stale : .live
            } else {
                state = .missing
            }
            entries.append(.init(label: "C", window: claudeSnapshot?.headline, state: state))
        }
        if Preferences.showCodex {
            let state: MenuBarIconRenderer.DataState
            if codexErrorMessage != nil {
                state = .error
            } else if let snapshot = codexSnapshot {
                state = snapshot.isStale ? .stale : .live
            } else {
                state = .missing
            }
            entries.append(.init(label: "X", window: codexSnapshot?.headline, state: state))
        }
        statusItem.length = MenuBarIconRenderer.iconWidth(entryCount: entries.count) + 4
        let image = MenuBarIconRenderer.render(entries: entries)
        image.accessibilityDescription = "ClaudeとCodexのレート使用率"
        statusItem.button?.image = image
        statusItem.button?.setAccessibilityLabel("RateGadget")
        statusItem.button?.setAccessibilityValue(accessibilitySummary())
    }

    private func refreshForTimePassage() {
        refreshIcon()
        if menuIsOpen {
            rebuildWhenSafe()
        }
    }

    private func accessibilitySummary() -> String {
        var values: [String] = []
        if Preferences.showClaude {
            let value = formatPercent(claudeSnapshot?.headline?.usedPercent)
            values.append(
                "Claude \(value)\(claudeErrorMessage != nil || statusLineMessage != nil || claudeSnapshot?.isStale == true ? "、取得異常" : "")"
            )
        }
        if Preferences.showCodex {
            let value = formatPercent(codexSnapshot?.headline?.usedPercent)
            values.append("Codex \(value)\(codexErrorMessage != nil || codexSnapshot?.isStale == true ? "、取得異常" : "")")
        }
        return values.isEmpty ? "すべて非表示" : values.joined(separator: "、")
    }

    /// Rebuilds the menu contents each time it is about to open, so the data
    /// rows are always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenuNow()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    /// NSMenu reflects item changes while open, so this also serves the
    /// toggle rows: flipping a switch restructures the visible menu in place.
    private func rebuildMenuNow() {
        menu.removeAllItems()
        buildMenu(into: menu)
        builtStructure = currentStructure()
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
                // Claude only reports usage while a Claude Code session is being
                // used, so always spell out how to refresh it. Flag it when the
                // value has gone stale, but keep the actionable hint either way.
                let staleness = formatStaleness(snapshot.stalenessInterval)
                let prefix = snapshot.isStale ? "⚠️ " : ""
                menu.addItem(infoItem("\(prefix)最終更新 \(staleness)"))
            } else {
                menu.addItem(infoItem("データ未取得"))
                menu.addItem(infoItem("Claudeへ送信し、応答が完了すると最大5秒で表示されます"))
            }
            if let message = statusLineMessage {
                menu.addItem(infoItem("⚠️ \(message)"))
            }
            if let error = claudeErrorMessage {
                menu.addItem(infoItem("⚠️ \(error)"))
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
            if let snapshot = codexSnapshot {
                let prefix = snapshot.isStale ? "⚠️ " : ""
                menu.addItem(infoItem("\(prefix)最終取得 \(formatStaleness(snapshot.stalenessInterval))"))
            } else if codexErrorMessage == nil {
                menu.addItem(infoItem("データ未取得"))
            }
        }

        if Preferences.showClaude || Preferences.showCodex {
            menu.addItem(.separator())
        }

        let claudeToggle = NSMenuItem(
            title: "Claude を表示",
            action: #selector(toggleClaudeVisibility),
            keyEquivalent: ""
        )
        claudeToggle.target = self
        claudeToggle.state = Preferences.showClaude ? .on : .off
        claudeToggle.isEnabled = true
        menu.addItem(claudeToggle)

        let codexToggle = NSMenuItem(
            title: "Codex を表示",
            action: #selector(toggleCodexVisibility),
            keyEquivalent: ""
        )
        codexToggle.target = self
        codexToggle.state = Preferences.showCodex ? .on : .off
        codexToggle.isEnabled = true
        menu.addItem(codexToggle)

        if let generalMessage {
            menu.addItem(infoItem("⚠️ \(generalMessage)"))
        }

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
            note: formatResetsAt(claudeSnapshot?.fiveHour?.resetsAt),
            isStale: claudeSnapshot?.isStale ?? false,
            hasError: claudeErrorMessage != nil || statusLineMessage != nil
        )
    }

    private func claudeSevenContent() -> DetailRowView.Content {
        .init(
            label: "週次",
            window: claudeSnapshot?.sevenDay,
            note: formatResetsAt(claudeSnapshot?.sevenDay?.resetsAt),
            isStale: claudeSnapshot?.isStale ?? false,
            hasError: claudeErrorMessage != nil || statusLineMessage != nil
        )
    }

    private func codexPrimaryContent() -> DetailRowView.Content {
        .init(
            label: codexSnapshot?.primary?.durationLabel ?? "primary",
            window: codexSnapshot?.primary,
            note: formatResetsAt(codexSnapshot?.primary?.resetsAt),
            isStale: codexSnapshot?.isStale ?? false,
            hasError: codexErrorMessage != nil
        )
    }

    private func codexSecondaryContent() -> DetailRowView.Content {
        .init(
            label: codexSnapshot?.secondary?.durationLabel ?? "secondary",
            window: codexSnapshot?.secondary,
            note: formatResetsAt(codexSnapshot?.secondary?.resetsAt),
            isStale: codexSnapshot?.isStale ?? false,
            hasError: codexErrorMessage != nil
        )
    }

    /// Pushes fresh snapshot data into the rows of the currently built menu,
    /// so an open menu updates in place (DetailRowView redraws on content set).
    /// If the update changes the menu's shape (a section or info row appears /
    /// disappears), the open menu is rebuilt instead.
    private func updateOpenMenuRows() {
        guard menuIsOpen else { return }
        if builtStructure != currentStructure() {
            rebuildWhenSafe()
            return
        }
        claudeFiveRow?.content = claudeFiveContent()
        claudeSevenRow?.content = claudeSevenContent()
        codexPrimaryRow?.content = codexPrimaryContent()
        codexSecondaryRow?.content = codexSecondaryContent()
    }

    private func headerItem(title: String, showsRefresh: Bool, onRefresh: (() -> Void)?) -> NSMenuItem {
        let view = SectionHeaderRowView(title: title, showsRefresh: showsRefresh)
        view.onRefresh = onRefresh
        let item = NSMenuItem()
        // Must stay enabled when it hosts the refresh button — disabled items'
        // views don't receive mouse events.
        item.isEnabled = showsRefresh
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
        let item = NSMenuItem()
        item.isEnabled = false
        item.view = InfoRowView(text: text)
        return item
    }

    private func setClaudeVisible(_ visible: Bool) {
        if visible {
            Preferences.showClaude = true
            generalMessage = nil
            startClaude()
        } else {
            let result = StatusLineInstaller.uninstall()
            guard !result.installed else {
                generalMessage = result.message
                scheduleMenuRebuild()
                return
            }
            Preferences.showClaude = false
            claudeWatcher.stop()
            claudeSnapshot = nil
            claudeErrorMessage = nil
            statusLineMessage = nil
            generalMessage = nil
        }
        refreshIcon()
        scheduleMenuRebuild()
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
        scheduleMenuRebuild()
    }

    @objc private func toggleClaudeVisibility() {
        setClaudeVisible(!Preferences.showClaude)
    }

    @objc private func toggleCodexVisibility() {
        setCodexVisible(!Preferences.showCodex)
    }

    /// Defer menu mutation until the current AppKit menu event has completed.
    private func scheduleMenuRebuild() {
        DispatchQueue.main.async { [weak self] in
            self?.rebuildWhenSafe()
        }
    }

    private func rebuildWhenSafe() {
        guard NSEvent.pressedMouseButtons == 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.rebuildWhenSafe()
            }
            return
        }
        rebuildMenuNow()
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
            generalMessage = nil
        } catch {
            NSLog("[RateGadget] login item toggle failed: %@", error.localizedDescription)
            generalMessage = "ログイン項目を変更できませんでした: \(error.localizedDescription)"
        }
        scheduleMenuRebuild()
    }

    func shutdown() {
        freshnessTimer?.invalidate()
        freshnessTimer = nil
        claudeWatcher.stop()
        codexPoller.shutdown()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
