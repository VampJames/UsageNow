import Foundation

enum CodexAppServerError: Error, Equatable {
    case binaryNotFound
    case processFailed
    case timeout
    case rpcError(code: Int, message: String)
    case invalidResponse
    case processExited
    case notInitialized
}

struct CodexRateLimitWindow: Decodable, Equatable, Sendable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Int?
}

/// Official App Server shape for `rateLimits` and `rateLimitsByLimitId["codex"]`.
struct RateLimitSnapshot: Decodable, Equatable, Sendable {
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?

    init(primary: CodexRateLimitWindow? = nil, secondary: CodexRateLimitWindow? = nil) {
        self.primary = primary
        self.secondary = secondary
    }
}

struct CodexRateLimitsPayload: Decodable, Equatable, Sendable {
    let rateLimits: RateLimitSnapshot?
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?

    init(
        rateLimits: RateLimitSnapshot? = nil,
        rateLimitsByLimitId: [String: RateLimitSnapshot]? = nil
    ) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitId = rateLimitsByLimitId
    }
}

enum CodexRateLimitsParser {
    static func rateLimitSnapshot(in payload: CodexRateLimitsPayload) -> RateLimitSnapshot? {
        payload.rateLimitsByLimitId?["codex"] ?? payload.rateLimits
    }

    static func windows(in payload: CodexRateLimitsPayload) -> (fiveHour: CodexRateLimitWindow?, weekly: CodexRateLimitWindow?) {
        let collected = windowsDefined(in: payload)
        return mapByDuration(collected)
    }

    static func parse(from payload: CodexRateLimitsPayload) -> (fiveHour: CodexRateLimitWindow?, weekly: CodexRateLimitWindow?) {
        windows(in: payload)
    }

    private static func windowsDefined(in payload: CodexRateLimitsPayload) -> [CodexRateLimitWindow] {
        guard let snapshot = rateLimitSnapshot(in: payload) else { return [] }
        return [snapshot.primary, snapshot.secondary].compactMap { $0 }
    }

    private static func mapByDuration(_ windows: [CodexRateLimitWindow]) -> (fiveHour: CodexRateLimitWindow?, weekly: CodexRateLimitWindow?) {
        var fiveHour: CodexRateLimitWindow?
        var weekly: CodexRateLimitWindow?
        for window in windows {
            guard let mins = window.windowDurationMins else { continue }
            if mins == 300 {
                fiveHour = window
            } else if mins == 10080 {
                weekly = window
            }
        }
        return (fiveHour, weekly)
    }

    /// Merges a sparse `account/rateLimits/updated` payload with the last full read.
    static func merged(previous: CodexRateLimitsPayload?, update: CodexRateLimitsPayload) -> CodexRateLimitsPayload {
        guard let previous else { return update }
        let prevSnap = rateLimitSnapshot(in: previous) ?? RateLimitSnapshot()
        let updSnap = rateLimitSnapshot(in: update) ?? RateLimitSnapshot()
        let mergedSnap = RateLimitSnapshot(
            primary: updSnap.primary ?? prevSnap.primary,
            secondary: updSnap.secondary ?? prevSnap.secondary
        )
        return CodexRateLimitsPayload(
            rateLimits: nil,
            rateLimitsByLimitId: ["codex": mergedSnap]
        )
    }

    static func snapshot(from payload: CodexRateLimitsPayload, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        let (fiveHour, weekly) = windows(in: payload)
        if fiveHour == nil && weekly == nil {
            throw CodexMappingError.missingWindows
        }
        return UsageSnapshot(
            provider: .codex,
            innerMetric: metric(from: fiveHour, title: "5 小时"),
            outerMetric: metric(from: weekly, title: "本周"),
            fetchedAt: fetchedAt
        )
    }

    static func metric(from window: CodexRateLimitWindow?, title: String) -> UsageMetric {
        guard let window else {
            return UsageMetric(title: title, percentUsed: .nan, resetAt: nil)
        }
        let percent = window.usedPercent ?? .nan
        let reset: Date? = window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return UsageMetric(title: title, percentUsed: percent, resetAt: reset)
    }

    static func decodeRateLimits(from data: Data) throws -> CodexRateLimitsPayload {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(RateLimitsResultEnvelope.self, from: data) {
            return envelope.result
        }
        if let notification = try? decoder.decode(RateLimitsNotificationEnvelope.self, from: data) {
            return notification.params
        }
        return try decoder.decode(CodexRateLimitsPayload.self, from: data)
    }
}

enum CodexMappingError: Error, Equatable {
    case missingWindows
}

private struct RateLimitsResultEnvelope: Decodable {
    let result: CodexRateLimitsPayload
}

private struct RateLimitsNotificationEnvelope: Decodable {
    let params: CodexRateLimitsPayload
}

protocol CodexBinaryLocating: Sendable {
    func locate() -> URL?
}

actor CodexAppServerClient {
    private let binaryLocator: CodexBinaryLocating
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var lineBuffer = Data()
    private var initialized = false
    private var updateContinuations: [UUID: AsyncStream<CodexRateLimitsPayload>.Continuation] = [:]
    private let requestTimeout: TimeInterval = 15

    init(binaryLocator: CodexBinaryLocating = CodexBinaryLocator()) {
        self.binaryLocator = binaryLocator
    }

    func rateLimitUpdates() -> AsyncStream<CodexRateLimitsPayload> {
        let id = UUID()
        return AsyncStream { continuation in
            updateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeUpdateContinuation(id) }
            }
        }
    }

    private func removeUpdateContinuation(_ id: UUID) {
        updateContinuations.removeValue(forKey: id)
    }

    func startIfNeeded() async throws {
        if process?.isRunning == true, initialized {
            return
        }
        if process != nil {
            await teardownProcess()
        }
        guard let binary = binaryLocator.locate() else {
            throw CodexAppServerError.binaryNotFound
        }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["app-server", "--stdio"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        proc.terminationHandler = { [weak self] _ in
            Task { await self?.handleProcessExit() }
        }

        try proc.run()
        if !proc.isRunning {
            throw CodexAppServerError.processExited
        }
        process = proc
        stdoutHandle = stdoutPipe.fileHandleForReading

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            Task { await self?.appendStdout(data) }
        }

        try await sendInitialize(stdin: stdinPipe)
        nextRequestID = 2
        initialized = true
    }

    func readRateLimits() async throws -> CodexRateLimitsPayload {
        try await startIfNeeded()
        let responseData = try await request(
            method: "account/rateLimits/read",
            params: NSNull(),
            stdin: process?.standardInput as? Pipe
        )
        return try CodexRateLimitsParser.decodeRateLimits(from: responseData)
    }

    func shutdown() async {
        if let proc = process, proc.isRunning {
            proc.terminate()
            let deadline = Date().addingTimeInterval(2)
            while proc.isRunning && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if proc.isRunning {
                proc.terminate()
            }
        }
        await teardownProcess()
    }

    private func teardownProcess() async {
        stdoutHandle?.readabilityHandler = nil
        failAllPending(CodexAppServerError.processExited)
        process = nil
        stdoutHandle = nil
        initialized = false
        lineBuffer = Data()
    }

    private func handleProcessExit() async {
        await teardownProcess()
    }

    private func sendInitialize(stdin: Pipe) async throws {
        let params: [String: Any] = [
            "clientInfo": [
                "name": "UsageNow",
                "title": "UsageNow",
                "version": "1.0.0",
            ],
        ]
        _ = try await request(method: "initialize", params: params, stdin: stdin, id: 1)
        try writeNotification(method: "initialized", params: [:], stdin: stdin.fileHandleForWriting)
    }

    private func request(
        method: String,
        params: Any?,
        stdin: Pipe?,
        id: Int? = nil
    ) async throws -> Data {
        let requestID = id ?? nextRequestID
        if id == nil {
            nextRequestID += 1
        }

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params is NSNull ? NSNull() : (params ?? NSNull()),
        ]
        try writeJSON(body, to: stdin?.fileHandleForWriting)

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation
            Task {
                try? await Task.sleep(nanoseconds: UInt64(requestTimeout * 1_000_000_000))
                await self.timeoutRequest(id: requestID)
            }
        }
    }

    private func timeoutRequest(id: Int) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: CodexAppServerError.timeout)
        }
    }

    private func failAllPending(_ error: Error) {
        for (_, cont) in pending {
            cont.resume(throwing: error)
        }
        pending.removeAll()
    }

    private func appendStdout(_ data: Data) {
        lineBuffer.append(data)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer[lineBuffer.startIndex..<newlineIndex]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            if !lineData.isEmpty {
                handleLine(Data(lineData))
            }
        }
    }

    private func handleLine(_ lineData: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return
        }

        if let method = json["method"] as? String {
            if method == "account/rateLimits/updated" {
                if let params = json["params"],
                   let data = try? JSONSerialization.data(withJSONObject: params),
                   let payload = try? CodexRateLimitsParser.decodeRateLimits(from: data)
                {
                    for (_, cont) in updateContinuations {
                        cont.yield(payload)
                    }
                }
            }
            return
        }

        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? -1
            let message = error["message"] as? String ?? "error"
            if let id = json["id"] as? Int, let cont = pending.removeValue(forKey: id) {
                cont.resume(throwing: CodexAppServerError.rpcError(code: code, message: message))
            }
            return
        }

        if let id = json["id"] as? Int, let cont = pending.removeValue(forKey: id) {
            if let result = json["result"] {
                if let data = try? JSONSerialization.data(withJSONObject: result) {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: CodexAppServerError.invalidResponse)
                }
            } else {
                cont.resume(returning: Data())
            }
        }
    }

    private func writeNotification(method: String, params: [String: Any], stdin: FileHandle) throws {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        try writeJSON(body, to: stdin)
    }

    private func writeJSON(_ object: [String: Any], to handle: FileHandle?) throws {
        guard let handle else { throw CodexAppServerError.processFailed }
        let data = try JSONSerialization.data(withJSONObject: object)
        var line = data
        line.append(0x0A)
        try handle.write(contentsOf: line)
    }
}

struct CodexBinaryLocator: CodexBinaryLocating {
    func locate() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return whichCodex()
    }

    private func whichCodex() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}
