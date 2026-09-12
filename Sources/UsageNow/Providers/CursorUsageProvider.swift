import Foundation

struct CursorUsageResponse: Decodable, Equatable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let planUsage: CursorPlanUsage?
}

struct CursorPlanUsage: Decodable, Equatable {
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
}

enum CursorUsageError: Error, Equatable {
    case notLoggedIn
    case unauthorized
    case notFound
    case tooManyRequests
    case serverError
    case schemaChanged
    case network
}

struct CursorUsageProvider: UsageProvider {
    let provider: UsageProviderKind = .cursor
    private let tokenReader: CursorTokenReading
    private let transport: HTTPTransport

    init(tokenReader: CursorTokenReading = CursorTokenReader(), transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.tokenReader = tokenReader
        self.transport = transport
    }

    func fetch() async throws -> UsageSnapshot {
        let token: String
        do {
            token = try tokenReader.readAccessToken()
        } catch let error as CursorTokenError {
            throw error
        }

        let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
        let request = HTTPRequest(
            url: url,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(token)",
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
            ],
            body: Data("{}".utf8),
            timeout: 15
        )

        let response: HTTPResponse
        do {
            response = try await transport.data(for: request)
        } catch {
            throw CursorUsageError.network
        }

        switch response.statusCode {
        case 200:
            break
        case 401, 403:
            throw CursorUsageError.unauthorized
        case 404:
            throw CursorUsageError.notFound
        case 429:
            throw CursorUsageError.tooManyRequests
        case 500...599:
            throw CursorUsageError.serverError
        default:
            throw CursorUsageError.network
        }

        let decoded = try decodeUsage(from: response.body)
        guard let plan = decoded.planUsage,
              let api = plan.apiPercentUsed,
              let auto = plan.autoPercentUsed
        else {
            throw CursorUsageError.schemaChanged
        }

        return UsageSnapshot(
            provider: .cursor,
            innerMetric: UsageMetric(title: "Other Models", percentUsed: api, resetAt: nil),
            outerMetric: UsageMetric(title: "Cursor Models", percentUsed: auto, resetAt: nil),
            fetchedAt: Date()
        )
    }

    private func decodeUsage(from data: Data) throws -> CursorUsageResponse {
        do {
            return try JSONDecoder().decode(CursorUsageResponse.self, from: data)
        } catch {
            throw CursorUsageError.schemaChanged
        }
    }
}

enum CursorUserFacingError {
    static func message(for error: Error) -> String {
        if let tokenError = error as? CursorTokenError, tokenError == .notLoggedIn {
            return "未检测到 Cursor 登录信息，请先登录 Cursor。"
        }
        if let usage = error as? CursorUsageError {
            switch usage {
            case .notLoggedIn:
                return "未检测到 Cursor 登录信息，请先登录 Cursor。"
            case .unauthorized:
                return "Cursor 登录已失效，请重新登录 Cursor"
            case .notFound:
                return "Cursor 用量接口不可用"
            case .tooManyRequests:
                return "请求过于频繁"
            case .serverError, .network:
                return "Cursor 网络或服务异常"
            case .schemaChanged:
                return "Cursor 数据接口已变化"
            }
        }
        return "Cursor 数据读取失败"
    }

    static func isStalePreserving(error: Error) -> Bool {
        if case CursorUsageError.tooManyRequests = error { return true }
        if case CursorUsageError.serverError = error { return true }
        if case CursorUsageError.network = error { return true }
        return false
    }
}
