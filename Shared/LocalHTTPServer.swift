import Foundation
import Network

/// Minimal HTTP/1.1 server for the local network, used to let the TV pull exactly one
/// selected resource (photo, video, or the mirroring receiver page).
///
/// Security model:
/// - Only explicitly registered resources are served, each under an unguessable 128-bit
///   token path with an expiry; everything else is 404. No directory listing, no file paths.
/// - Optionally only a specific client address (the selected TV) is accepted.
/// - The server stops (and all tokens die) when the casting session ends.
/// Accepting incoming connections does not require Local Network permission (TN3179).
final class LocalHTTPServer: @unchecked Sendable {
    enum Body: Sendable {
        case data(Data)
        case file(URL)
    }

    struct Resource: Sendable {
        let body: Body
        let contentType: String
        let expiresAt: Date
        /// DLNA transfer mode hint: "Streaming" for A/V, "Interactive" for images/pages.
        let dlnaTransferMode: String?
        let dlnaContentFeatures: String?
    }

    private let queue = DispatchQueue(label: "local.http.server")
    private var listener: NWListener?
    private var resources: [String: Resource] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let lock = NSLock()
    private(set) var port: UInt16?
    /// If set, requests from other addresses are rejected with 403.
    var allowedClientHost: String?

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    func start(preferredPort: UInt16? = nil) async throws -> UInt16 {
        if let port { return port }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        let listener: NWListener
        if let preferredPort, let nwPort = NWEndpoint.Port(rawValue: preferredPort), let preferred = try? NWListener(using: parameters, on: nwPort) {
            listener = preferred
        } else {
            listener = try NWListener(using: parameters)
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let port = listener.port?.rawValue ?? 0
                    self?.lock.withLock { self?.port = port }
                    if once.claim() { continuation.resume(returning: port) }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let open = lock.withLock { () -> [NWConnection] in
            defer { connections.removeAll(); resources.removeAll(); port = nil }
            return Array(connections.values)
        }
        open.forEach { $0.cancel() }
    }

    /// Registers a resource and returns its path (e.g. "/m/<token>/photo.jpg").
    func register(_ resource: Resource, fileName: String) -> String {
        let token = Self.makeToken()
        let safeName = fileName.replacingOccurrences(of: "/", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
        lock.withLock { resources[token] = resource }
        return "/m/\(token)/\(safeName)"
    }

    func unregisterAll() {
        lock.withLock { resources.removeAll() }
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        if let allowed = allowedClientHost, case .hostPort(let host, _) = connection.endpoint {
            let remote = "\(host)".split(separator: "%").first.map(String.init) ?? ""
            if remote != allowed && remote != "::ffff:\(allowed)" {
                connection.start(queue: queue)
                respond(connection, status: 403, reason: "Forbidden", headers: [:], body: nil, method: "GET")
                return
            }
        }
        lock.withLock { connections[ObjectIdentifier(connection)] = connection }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .failed, .cancelled:
                self?.lock.withLock { _ = self?.connections.removeValue(forKey: ObjectIdentifier(connection)) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if let range = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: accumulated[..<range.lowerBound], as: UTF8.self)
                self.handle(head, connection)
            } else if accumulated.count > 32 * 1024 || isComplete || error != nil {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: accumulated)
            }
        }
    }

    struct ParsedRequest: Equatable {
        let method: String
        let path: String
        let headers: [String: String]
    }

    static func parse(_ head: String) -> ParsedRequest? {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let index = line.firstIndex(of: ":") else { continue }
            headers[line[..<index].lowercased()] = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
        }
        return ParsedRequest(method: String(parts[0]).uppercased(), path: String(parts[1]), headers: headers)
    }

    /// Parses "bytes=start-end" against a total length. Returns nil for no/invalid range.
    static func byteRange(_ header: String?, total: Int) -> ClosedRange<Int>? {
        guard let header, header.hasPrefix("bytes="), total > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map { String($0) }
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty, let suffix = Int(bounds[1]), suffix > 0 {
            return max(0, total - suffix)...(total - 1)
        }
        guard let start = Int(bounds[0]), start < total else { return nil }
        let end = Int(bounds[1]).map { min($0, total - 1) } ?? (total - 1)
        return start <= end ? start...end : nil
    }

    private func handle(_ head: String, _ connection: NWConnection) {
        guard let request = Self.parse(head), request.method == "GET" || request.method == "HEAD" else {
            respond(connection, status: 405, reason: "Method Not Allowed", headers: [:], body: nil, method: "GET")
            return
        }
        let components = request.path.split(separator: "/")
        guard components.count >= 2, components[0] == "m" else {
            respond(connection, status: 404, reason: "Not Found", headers: [:], body: nil, method: request.method)
            return
        }
        let token = String(components[1])
        let resource = lock.withLock { resources[token] }
        guard let resource, resource.expiresAt > Date() else {
            respond(connection, status: 404, reason: "Not Found", headers: [:], body: nil, method: request.method)
            return
        }

        var headers: [String: String] = [
            "Content-Type": resource.contentType,
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
        ]
        if let mode = resource.dlnaTransferMode { headers["transferMode.dlna.org"] = mode }
        if let features = resource.dlnaContentFeatures { headers["contentFeatures.dlna.org"] = features }

        switch resource.body {
        case .data(let data):
            if let range = Self.byteRange(request.headers["range"], total: data.count) {
                headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(data.count)"
                respond(connection, status: 206, reason: "Partial Content", headers: headers, body: data.subdata(in: range.lowerBound..<(range.upperBound + 1)), method: request.method)
            } else {
                respond(connection, status: 200, reason: "OK", headers: headers, body: data, method: request.method)
            }
        case .file(let url):
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
            else {
                respond(connection, status: 404, reason: "Not Found", headers: [:], body: nil, method: request.method)
                return
            }
            var status = 200, reason = "OK"
            var range = 0...(max(size, 1) - 1)
            if let requested = Self.byteRange(request.headers["range"], total: size) {
                range = requested
                status = 206
                reason = "Partial Content"
                headers["Content-Range"] = "bytes \(requested.lowerBound)-\(requested.upperBound)/\(size)"
            }
            headers["Content-Length"] = "\(size == 0 ? 0 : range.count)"
            headers["Connection"] = "close"
            let headerData = Self.headerData(status: status, reason: reason, headers: headers)
            connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
                guard error == nil, request.method == "GET", size > 0 else {
                    try? handle.close()
                    connection.cancel()
                    return
                }
                try? handle.seek(toOffset: UInt64(range.lowerBound))
                self?.stream(handle, remaining: range.count, connection: connection)
            })
        }
    }

    /// Sends a file in chunks, waiting for each chunk to be processed (bounded memory).
    private func stream(_ handle: FileHandle, remaining: Int, connection: NWConnection) {
        guard remaining > 0 else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let chunk = (try? handle.read(upToCount: min(256 * 1024, remaining))) ?? nil
        guard let chunk, !chunk.isEmpty else {
            try? handle.close()
            connection.cancel()
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error != nil {
                try? handle.close()
                connection.cancel()
                return
            }
            self?.stream(handle, remaining: remaining - chunk.count, connection: connection)
        })
    }

    private func respond(_ connection: NWConnection, status: Int, reason: String, headers: [String: String], body: Data?, method: String) {
        var headers = headers
        headers["Content-Length"] = "\(body?.count ?? 0)"
        headers["Connection"] = "close"
        var payload = Self.headerData(status: status, reason: reason, headers: headers)
        if method != "HEAD", let body { payload.append(body) }
        connection.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func headerData(status: Int, reason: String, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason)\r\nServer: TVRemote/1.0\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(key): \(value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }
}
