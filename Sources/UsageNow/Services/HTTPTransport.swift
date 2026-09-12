import Foundation

struct HTTPRequest: Sendable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data?
    let timeout: TimeInterval
}

struct HTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

protocol HTTPTransport: Sendable {
    func data(for request: HTTPRequest) async throws -> HTTPResponse
}

struct URLSessionHTTPTransport: HTTPTransport {
    func data(for request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPTransportError.invalidResponse
        }
        return HTTPResponse(statusCode: http.statusCode, body: data)
    }
}

enum HTTPTransportError: Error, Equatable {
    case invalidResponse
}
