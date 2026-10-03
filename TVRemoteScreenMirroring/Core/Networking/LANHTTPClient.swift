import Foundation

/// Short-timeout HTTP requests to devices on the local network. No caching, no cookies.
struct LANHTTPClient: Sendable {
    let timeout: TimeInterval

    init(timeout: TimeInterval = 4) {
        self.timeout = timeout
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    struct Response: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) async throws -> Response {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.deviceUnreachable }
        var normalized: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { normalized[key.lowercased()] = value }
        }
        return Response(status: http.statusCode, headers: normalized, body: data)
    }

    func json(_ url: URL, method: String = "GET") async throws -> [String: Any] {
        let response = try await request(url, method: method)
        guard (200..<300).contains(response.status),
              let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else { throw AppError.deviceUnreachable }
        return object
    }
}
