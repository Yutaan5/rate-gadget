import Foundation

/// Watches the shared JSON file written by `claude-statusline.sh` and exposes
/// the latest Claude Code rate-limit snapshot. Uses a filesystem event source
/// for near-instant updates plus a fallback poll in case events are missed
/// (e.g. the file didn't exist yet when we started watching).
final class ClaudeRateLimitWatcher {
    var onUpdate: ((ClaudeRateSnapshot) -> Void)?

    private let fileURL = StatusLineInstaller.supportDir.appendingPathComponent("claude-rate.json")
    private let queue = DispatchQueue(label: "rate-gadget.claude-watcher")
    private var source: DispatchSourceFileSystemObject?
    private var fallbackTimer: DispatchSourceTimer?
    private var fileDescriptor: Int32 = -1

    func start() {
        queue.async { [weak self] in
            self?.readAndNotify()
            self?.watchFile()
            self?.scheduleFallbackPoll()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.source?.cancel()
            self?.source = nil
            self?.fallbackTimer?.cancel()
            self?.fallbackTimer = nil
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
            self?.fileDescriptor = -1
        }
    }

    private func watchFile() {
        source?.cancel()
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }

        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet (Claude hasn't run since install) — rely on
            // the fallback poll to notice once it's created.
            return
        }
        fileDescriptor = fd

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        newSource.setEventHandler { [weak self] in
            self?.readAndNotify()
            // A `rename` (atomic replace via mv) invalidates the descriptor;
            // re-open so future writes are still observed.
            self?.watchFile()
        }
        newSource.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
        }
        newSource.resume()
        source = newSource
    }

    private func scheduleFallbackPoll() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.readAndNotify()
            if self?.fileDescriptor ?? -1 < 0 {
                self?.watchFile()
            }
        }
        timer.resume()
        fallbackTimer = timer
    }

    private func readAndNotify() {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        guard let updatedAtSecs = obj["updated_at"] as? Double ?? (obj["updated_at"] as? Int).map(Double.init) else {
            return
        }
        let snapshot = ClaudeRateSnapshot(
            fiveHour: Self.parseWindow(obj["five_hour"]),
            sevenDay: Self.parseWindow(obj["seven_day"]),
            updatedAt: Date(timeIntervalSince1970: updatedAtSecs)
        )
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(snapshot)
        }
    }

    private static func parseWindow(_ raw: Any?) -> RateWindow? {
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
