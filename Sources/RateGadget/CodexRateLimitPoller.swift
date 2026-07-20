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
    private var stderrBuffer = Data()
    private var nextRequestId = 1
    private var pendingRequests: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var pollTimer: DispatchSourceTimer?
    private var restartWorkItem: DispatchWorkItem?
    private var restartAttempt = 0
    private var isStopped = true
    private var rateLimitRequestInFlight = false

    let pollInterval: TimeInterval
    let requestTimeout: TimeInterval

    init(pollInterval: TimeInterval = 60, requestTimeout: TimeInterval = 15) {
        self.pollInterval = pollInterval
        self.requestTimeout = requestTimeout
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.isStopped && (self.process != nil || self.restartWorkItem != nil) { return }
            self.isStopped = false
            self.restartWorkItem?.cancel()
            self.restartWorkItem = nil
            self.launchProcess()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    /// Synchronous shutdown for application termination, preventing an orphaned
    /// app-server from surviving its menu-bar parent.
    func shutdown() {
        queue.sync {
            stopLocked()
        }
    }

    /// Force an immediate refresh, outside the regular poll cadence.
    func refreshNow() {
        queue.async { [weak self] in
            self?.requestRateLimits()
        }
    }

    private func stopLocked() {
        isStopped = true
        restartWorkItem?.cancel()
        restartWorkItem = nil
        pollTimer?.cancel()
        pollTimer = nil

        let runningProcess = process
        process = nil
        stdinHandle = nil
        (runningProcess?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (runningProcess?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        runningProcess?.terminate()

        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
        pendingRequests.removeAll()
        rateLimitRequestInFlight = false
    }

    // MARK: - Process lifecycle

    private func launchProcess() {
        guard !isStopped, process == nil else { return }
        pendingRequests.removeAll()
        rateLimitRequestInFlight = false

        let launchedProcess = Process()
        launchedProcess.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A login shell resolves version managers in the same way as Terminal.
        launchedProcess.arguments = ["-l", "-c", "exec codex app-server"]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        launchedProcess.standardInput = stdin
        launchedProcess.standardOutput = stdout
        launchedProcess.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak launchedProcess] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                guard let self, let launchedProcess, self.process === launchedProcess else { return }
                self.consumeStdout(data)
            }
        }
        // A pipe must always be drained. Otherwise a verbose child can fill the
        // kernel buffer and block forever while appearing to be alive.
        stderr.fileHandleForReading.readabilityHandler = { [weak self, weak launchedProcess] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                guard let self, let launchedProcess, self.process === launchedProcess else { return }
                self.stderrBuffer.append(data)
                let maximumBytes = 8 * 1024
                if self.stderrBuffer.count > maximumBytes {
                    self.stderrBuffer.removeFirst(self.stderrBuffer.count - maximumBytes)
                }
            }
        }

        launchedProcess.terminationHandler = { [weak self] terminatedProcess in
            self?.queue.async { self?.handleTermination(of: terminatedProcess) }
        }

        process = launchedProcess
        do {
            try launchedProcess.run()
        } catch {
            process = nil
            publishError("codex app-server の起動に失敗しました: \(error.localizedDescription)")
            scheduleRestart()
            return
        }

        stdinHandle = stdin.fileHandleForWriting
        stdoutBuffer.removeAll()
        stderrBuffer.removeAll()
        sendInitialize()
    }

    private func handleTermination(of terminatedProcess: Process) {
        guard terminatedProcess === process else { return }
        (terminatedProcess.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (terminatedProcess.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinHandle = nil
        stdoutBuffer.removeAll()
        pollTimer?.cancel()
        pollTimer = nil
        pendingRequests.removeAll()
        rateLimitRequestInFlight = false

        guard !isStopped else { return }
        let details = String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        stderrBuffer.removeAll()
        let suffix = details.flatMap { $0.isEmpty ? nil : String($0.suffix(300)) }
        publishError(
            suffix.map { "codex app-server が終了しました: \($0)" }
                ?? "codex app-server が終了しました"
        )
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !isStopped, restartWorkItem == nil else { return }
        restartAttempt += 1
        let delay = min(60.0, pow(2.0, Double(restartAttempt)))
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            guard !self.isStopped else { return }
            self.launchProcess()
        }
        restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func schedulePolling() {
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
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
            guard let self else { return }
            switch result {
            case .success:
                self.sendNotification(method: "initialized")
                self.requestRateLimits()
                self.schedulePolling()
            case .failure(let error):
                self.publishError("initialize に失敗しました: \(error.localizedDescription)")
                self.process?.terminate()
            }
        }
    }

    private func requestRateLimits() {
        guard !rateLimitRequestInFlight else { return }
        rateLimitRequestInFlight = true
        send(method: "account/rateLimits/read", params: nil) { [weak self] result in
            guard let self else { return }
            self.rateLimitRequestInFlight = false
            switch result {
            case .success(let payload):
                guard let snapshot = Self.parseSnapshot(from: payload) else {
                    self.publishError("Codexのレート応答を解釈できませんでした")
                    return
                }
                self.restartAttempt = 0
                DispatchQueue.main.async { [weak self] in
                    self?.onUpdate?(snapshot)
                }
            case .failure(let error):
                self.publishError("レート取得に失敗しました: \(error.localizedDescription)")
                if let pollerError = error as? PollerError,
                   case .requestTimedOut = pollerError {
                    self.process?.terminate()
                }
            }
        }
    }

    private func send(
        method: String,
        params: [String: Any]?,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
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
        queue.asyncAfter(deadline: .now() + requestTimeout) { [weak self] in
            guard let self, let timedOut = self.pendingRequests.removeValue(forKey: id) else { return }
            timedOut(.failure(PollerError.requestTimedOut))
        }

        do {
            try writeLine(data, to: stdinHandle)
        } catch {
            pendingRequests.removeValue(forKey: id)
            completion(.failure(error))
        }
    }

    private func sendNotification(method: String) {
        guard let stdinHandle else { return }
        let message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        do {
            try writeLine(data, to: stdinHandle)
        } catch {
            publishError("Codexへの通知送信に失敗しました: \(error.localizedDescription)")
        }
    }

    private func writeLine(_ data: Data, to handle: FileHandle) throws {
        var line = data
        line.append(0x0A)
        try handle.write(contentsOf: line)
    }

    private func consumeStdout(_ data: Data) {
        stdoutBuffer.append(data)
        if stdoutBuffer.count > 1024 * 1024,
           !stdoutBuffer.contains(0x0A) {
            stdoutBuffer.removeAll()
            publishError("Codexから大きすぎる不正な応答を受信しました")
            process?.terminate()
            return
        }
        while let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newlineIndex]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }
            handleLine(Data(lineData))
        }
    }

    private func handleLine(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int else {
            // Notifications and non-JSON shell startup output are not responses.
            return
        }
        guard let completion = pendingRequests.removeValue(forKey: id) else { return }

        if let errorObject = object["error"] as? [String: Any] {
            let message = errorObject["message"] as? String ?? "unknown error"
            completion(.failure(PollerError.rpcError(message)))
            return
        }
        guard let result = object["result"] as? [String: Any] else {
            completion(.failure(PollerError.invalidResponse))
            return
        }
        completion(.success(result))
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }

    // MARK: - Parsing

    static func parseSnapshot(from payload: [String: Any]) -> CodexRateSnapshot? {
        guard let rateLimits = payload["rateLimits"] as? [String: Any] else { return nil }
        let planType = rateLimits["planType"] as? String
        let primary = parseWindow(rateLimits["primary"])
        let secondary = parseWindow(rateLimits["secondary"])
        guard primary != nil || secondary != nil else { return nil }
        return CodexRateSnapshot(
            primary: primary,
            secondary: secondary,
            planType: planType,
            updatedAt: Date()
        )
    }

    private static func parseWindow(_ raw: Any?) -> RateWindow? {
        guard let dictionary = raw as? [String: Any],
              let usedPercent = dictionary["usedPercent"] as? Int else { return nil }
        let resetsAt = (dictionary["resetsAt"] as? Int).map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }
        let windowDurationMins = dictionary["windowDurationMins"] as? Int
        return RateWindow(
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            windowDurationMins: windowDurationMins
        )
    }
}

enum PollerError: LocalizedError {
    case notConnected
    case encodingFailed
    case invalidResponse
    case requestTimedOut
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "codex app-server に接続されていません"
        case .encodingFailed: return "リクエストのエンコードに失敗しました"
        case .invalidResponse: return "Codexから不正な応答を受信しました"
        case .requestTimedOut: return "Codexからの応答がタイムアウトしました"
        case .rpcError(let message): return message
        }
    }
}
