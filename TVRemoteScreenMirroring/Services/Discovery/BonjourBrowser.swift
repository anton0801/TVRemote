import Foundation
import Network

/// Browses the Bonjour service types declared in `NSBonjourServices` and resolves them to
/// IPv4 addresses. Denial of Local Network access is reported explicitly.
final class BonjourBrowser: @unchecked Sendable {
    struct Record: Sendable, Hashable {
        let serviceType: String
        let name: String
        let host: String
        let port: UInt16
        let txt: [String: String]
    }

    enum Event: Sendable {
        case found(Record)
        case permissionDenied
        case failed
    }

    static let androidTV = "_androidtvremote2._tcp"
    static let airPlay = "_airplay._tcp"

    private let queue = DispatchQueue(label: "bonjour.browser")
    private var browsers: [NWBrowser] = []
    private var resolving: [NWConnection] = []
    private let channel = EventChannel<Event>(buffer: 128)
    private let lock = NSLock()

    var events: AsyncStream<Event> { channel.stream }

    func start(types: [String] = [BonjourBrowser.androidTV, BonjourBrowser.airPlay]) {
        for type in types {
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: parameters)
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .waiting(let error), .failed(let error):
                    if case .dns(let code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                        self?.channel.continuation.yield(.permissionDenied)
                    } else if case .failed = state {
                        self?.channel.continuation.yield(.failed)
                    }
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                for result in results { self?.resolve(result, type: type) }
            }
            browser.start(queue: queue)
            lock.withLock { browsers.append(browser) }
        }
    }

    func stop() {
        let (activeBrowsers, activeConnections) = lock.withLock { () -> ([NWBrowser], [NWConnection]) in
            defer { browsers.removeAll(); resolving.removeAll() }
            return (browsers, resolving)
        }
        activeBrowsers.forEach { $0.cancel() }
        activeConnections.forEach { $0.cancel() }
        channel.continuation.finish()
    }

    private func resolve(_ result: NWBrowser.Result, type: String) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata {
            txt = record.dictionary
        }
        // Resolve the service to an address by opening (and immediately closing) a TCP connection.
        let parameters = NWParameters.tcp
        if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOptions.version = .v4
        }
        let connection = NWConnection(to: result.endpoint, using: parameters)
        lock.withLock { resolving.append(connection) }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint,
                   let address = Self.ipv4(from: host) {
                    self.channel.continuation.yield(.found(Record(serviceType: type, name: name, host: address, port: port.rawValue, txt: txt)))
                }
                connection.cancel()
            case .waiting:
                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    self.channel.continuation.yield(.permissionDenied)
                }
                connection.cancel()
            case .failed:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 4) { [weak connection] in connection?.cancel() }
    }

    private static func ipv4(from host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let address):
            let text = "\(address)"
            return text.split(separator: "%").first.map(String.init)
        case .name(let name, _):
            return LocalNetworkInfo.octets(name) != nil ? name : nil
        default:
            return nil
        }
    }
}
