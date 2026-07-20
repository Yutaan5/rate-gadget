import Foundation

/// Reads the shared JSON file written by `claude-statusline.sh` on a short
/// timer and publishes the latest Claude Code rate-limit snapshot.
///
/// The bridge file is replaced atomically (`mv tmp file`), so its inode changes
/// on every write. A DispatchSource vnode watch tracks a single inode and would
/// need constant, race-prone re-arming to follow those swaps — in practice it
/// silently stopped following updates (notably after a login-launch), leaving a
/// stale inode held open. Polling the path directly sidesteps inode identity
/// entirely and survives sleep/wake and atomic replacement.
final class ClaudeRateLimitWatcher {
    var onUpdate: ((ClaudeRateSnapshot) -> Void)?
    var onError: ((String) -> Void)?

    private let fileURL = StatusLineInstaller.supportDir.appendingPathComponent("claude-rate.json")
    private let queue = DispatchQueue(label: "rate-gadget.claude-watcher")
    private var timer: DispatchSourceTimer?
    private var lastUpdatedAt: Double?
    private var lastErrorMessage: String?

    private static let pollInterval: TimeInterval = 5

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.lastUpdatedAt = nil // ensure the first read always publishes
            self.lastErrorMessage = nil
            self.readAndNotify()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
            timer.setEventHandler { [weak self] in
                self?.readAndNotify()
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func readAndNotify() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        let object: Any
        do {
            data = try Data(contentsOf: fileURL)
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            publishError("Claudeのレートファイルを読み取れません: \(error.localizedDescription)")
            return
        }
        guard let obj = object as? [String: Any],
              let updatedAtSecs = obj["updated_at"] as? Double
                ?? (obj["updated_at"] as? Int).map(Double.init) else {
            publishError("Claudeのレートファイルの形式が不正です")
            return
        }
        // Republish only when the snapshot actually changed.
        if let last = lastUpdatedAt, last == updatedAtSecs { return }
        lastUpdatedAt = updatedAtSecs

        let snapshot = ClaudeRateSnapshot(
            fiveHour: Self.parseWindow(obj["five_hour"]),
            sevenDay: Self.parseWindow(obj["seven_day"]),
            updatedAt: Date(timeIntervalSince1970: updatedAtSecs)
        )
        guard snapshot.fiveHour != nil || snapshot.sevenDay != nil else {
            publishError("Claudeのレート応答に使用率が含まれていません")
            return
        }
        lastErrorMessage = nil
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(snapshot)
        }
    }

    private func publishError(_ message: String) {
        guard message != lastErrorMessage else { return }
        lastErrorMessage = message
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    static func parseWindow(_ raw: Any?) -> RateWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        let percentRaw = dict["used_percentage"]
        let usedPercent: Int
        if let intVal = percentRaw as? Int {
            usedPercent = intVal
        } else if let doubleVal = percentRaw as? Double {
            usedPercent = Int(doubleVal.rounded())
        } else {
            return nil
        }
        var resetsAt: Date?
        if let secs = dict["resets_at"] as? Double {
            resetsAt = Date(timeIntervalSince1970: secs)
        } else if let secs = dict["resets_at"] as? Int {
            resetsAt = Date(timeIntervalSince1970: TimeInterval(secs))
        }
        return RateWindow(usedPercent: usedPercent, resetsAt: resetsAt, windowDurationMins: nil)
    }
}
