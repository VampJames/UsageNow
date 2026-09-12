import Foundation

struct CodexUsageProvider: UsageProvider {
    let provider: UsageProviderKind = .codex
    private let client: CodexAppServerClient

    init(client: CodexAppServerClient = CodexAppServerClient()) {
        self.client = client
    }

    func fetch() async throws -> UsageSnapshot {
        let payload = try await client.readRateLimits()
        return try CodexRateLimitsParser.snapshot(from: payload)
    }

    func clientForLifecycle() -> CodexAppServerClient {
        client
    }
}

enum CodexUserFacingError {
    static func message(for error: Error) -> String {
        if let err = error as? CodexAppServerError {
            switch err {
            case .binaryNotFound:
                return "未找到 Codex。请确认 ChatGPT 或 Codex CLI 已安装。"
            case .processExited, .processFailed, .timeout, .notInitialized:
                return "Codex 连接异常"
            case .rpcError, .invalidResponse:
                return "Codex 数据读取失败"
            }
        }
        if error is CodexMappingError {
            return "Codex 额度数据不完整"
        }
        return "Codex 数据读取失败"
    }
}
