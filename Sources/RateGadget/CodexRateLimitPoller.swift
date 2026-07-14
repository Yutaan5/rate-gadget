import Foundation

/// Manages a long-lived `codex app-server` subprocess and polls
/// `account/rateLimits/read` over its newline-delimited JSON-RPC stdio protocol.
final class CodexRateLimitPoller {
    var onUpdate: ((CodexRateSnapshot) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "rate-gadget.codex-poller")
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var nextRequestId = 1
    private var pendingRequests: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var pollTimer: DispatchSourceTimer?
    private var restartAttempt = 0
    private var isStopped = false

    let pollInterval: TimeInterval

    init(pollInterval: TimeInterval = 60) {
        self.pollInterval = pollInterval
    }

    func start() {
        queue.async { [weak self] in
            self?.isStopped = false
            self?.launchProcess()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.pollTimer?.cancel()
            self.pollTimer = nil
            self.process?.terminate()
            self.process = nil
            self.stdinHandle = nil
            self.stdoutBuffer.removeAll()
            for (_, completion) in self.pendingRequests {
                completion(.failure(PollerError.processExited))
            }
            self.pendingRequests.removeAll()
        }
    }

    /// Force an immediate refresh, outside the regular poll cadence.
    func refreshNow() {
        queue.async { [weak self] in
            self?.requestRateLimits()
        }
    }

    // MARK: - Process lifecycle

    private func launchProcess() {
        // Any requests still pending belong to a previous process instance.
        for (_, completion) in pendingRequests {
            completion(.failure(PollerError.processExited))
        }
        pendingRequests.removeAll()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Run through a login shell so version managers (nodenv/nvm/etc.) resolve
        // `codex` exactly as they would in the user's Terminal.
        process.arguments = ["-l", "-c", "exec codex app-server"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                guard let self, let process, self.process === process else { return }
                self.consumeStdout(data)
            }
        }

        process.terminationHandler = { [weak self] proc in
            self?.queue.async { self?.handleTermination(of: proc) }
        }

        do {
            try process.run()
        } catch {
            onError?("codex app-server の起動に失敗しました: \(error.localizedDescription)")
            scheduleRestart()
            return
        }

        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        self.stdoutBuffer.removeAll()
        self.restartAttempt = 0

        sendInitialize()
        schedulePolling()
    }

    private func handleTermination(of proc: Process) {
        // A stale handler from a process replaced by stop()/start() must not
        // tear down the current one (or double-restart).
        guard proc === process else { return }
        stdoutBuffer.removeAll()
        stdinHandle = nil
        process = nil
        pollTimer?.cancel()
        pollTimer = nil

        for (_, completion) in pendingRequests {
            completion(.failure(PollerError.processExited))
        }
        pendingRequests.removeAll()

        guard !isStopped else { return }
        scheduleRestart()
    }

    private func scheduleRestart() {
        restartAttempt += 1
        let delay = min(60.0, pow(2.0, Double(restartAttempt)))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.isStopped else { return }
            self.launchProcess()
        }
    }

    private func schedulePolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: pollInterval)
        timer.setEventHandler { [weak self] in
            self?.requestRateLimits()
        }
        timer.resume()
        pollTimer = timer
    }

    // MARK: - JSON-RPC

    private func sendInitialize() {
        let params: [String: Any] = [
            "clientInfo": [
                "name": "rate-gadget",
                "version": "0.1.0",
            ]
        ]
        send(method: "initialize", params: params) { [weak self] result in
            switch result {
            case .success:
                self?.requestRateLimits()
            case .failure(let error):
                self?.onError?("initialize に失敗しました: \(error.localizedDescription)")
            }
        }
    }

    private func requestRateLimits() {
        send(method: "account/rateLimits/read", params: nil) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let payload):
                if let snapshot = Self.parseSnapshot(from: payload) {
                    DispatchQueue.main.async {
                        self.onUpdate?(snapshot)
                    }
                }
            case .failure(let error):
                self.onError?("レート取得に失敗しました: \(error.localizedDescription)")
            }
        }
    }

    private func send(method: String, params: [String: Any]?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let stdinHandle else {
            completion(.failure(PollerError.notConnected))
            return
        }
        let id = nextRequestId
        nextRequestId += 1

        var message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        message["params"] = params ?? NSNull()

        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            completion(.failure(PollerError.encodingFailed))
            return
        }

        pendingRequests[id] = completion

        var line = data
        line.append(0x0A)
        do {
            try stdinHandle.write(contentsOf: line)
        } catch {
            pendingRequests.removeValue(forKey: id)
            completion(.failure(error))
        }
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newlineIndex]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }
            handleLine(Data(lineData))
        }
    }

    private func handleLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let id = obj["id"] as? Int else {
            // Notification (e.g. remoteControl/status/changed) — not relevant here.
            return
        }
        guard let completion = pendingRequests.removeValue(forKey: id) else { return }

        if let errorObj = obj["error"] as? [String: Any] {
            let message = errorObj["message"] as? String ?? "unknown error"
            completion(.failure(PollerError.rpcError(message)))
            return
        }
        let result = obj["result"] as? [String: Any] ?? [:]
        completion(.success(result))
    }

    // MARK: - Parsing

    private static func parseSnapshot(from payload: [String: Any]) -> CodexRateSnapshot? {
        guard let rateLimits = payload["rateLimits"] as? [String: Any] else { return nil }
        let planType = rateLimits["planType"] as? String
        let primary = parseWindow(rateLimits["primary"])
        let secondary = parseWindow(rateLimits["secondary"])
        return CodexRateSnapshot(primary: primary, secondary: secondary, planType: planType, updatedAt: Date())
    }

    private static func parseWindow(_ raw: Any?) -> RateWindow? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let usedPercent = dict["usedPercent"] as? Int else { return nil }
        var resetsAt: Date?
        if let resetsAtSecs = dict["resetsAt"] as? Int {
            resetsAt = Date(timeIntervalSince1970: TimeInterval(resetsAtSecs))
        }
        let windowDurationMins = dict["windowDurationMins"] as? Int
        return RateWindow(usedPercent: usedPercent, resetsAt: resetsAt, windowDurationMins: windowDurationMins)
    }
}

enum PollerError: LocalizedError {
    case notConnected
    case processExited
    case encodingFailed
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "codex app-server に接続されていません"
        case .processExited: return "codex app-server プロセスが終了しました"
        case .encodingFailed: return "リクエストのエンコードに失敗しました"
        case .rpcError(let message): return message
        }
    }
}
