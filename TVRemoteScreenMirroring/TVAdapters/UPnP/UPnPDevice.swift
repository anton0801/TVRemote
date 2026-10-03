import Foundation

/// Parsed UPnP root device description (only the fields we use).
struct UPnPDeviceDescription: Equatable, Sendable {
    struct Service: Equatable, Sendable {
        let serviceType: String
        let controlURL: URL
    }

    var deviceType: String
    var friendlyName: String
    var manufacturer: String?
    var modelName: String?
    var modelNumber: String?
    var udn: String
    var services: [Service]

    var isMediaRenderer: Bool { deviceType.contains("MediaRenderer") || service(containing: "AVTransport") != nil }

    func service(containing fragment: String) -> Service? {
        services.first { $0.serviceType.contains(fragment) }
    }

    static func fetch(_ location: URL, client: LANHTTPClient = LANHTTPClient(timeout: 3)) async throws -> UPnPDeviceDescription {
        let response = try await client.request(location)
        guard (200..<300).contains(response.status) else { throw AppError.mediaRendererMissing }
        guard let description = UPnPDescriptionParser.parse(response.body, baseURL: location) else { throw AppError.mediaRendererMissing }
        return description
    }
}

/// XMLParser-based parser. Picks the MediaRenderer device when the root embeds several.
final class UPnPDescriptionParser: NSObject, XMLParserDelegate {
    private struct DeviceBuilder {
        var fields: [String: String] = [:]
        var services: [(type: String, control: String)] = []
    }

    private let baseURL: URL
    private var urlBase: URL?
    private var stack: [String] = []
    private var devices: [DeviceBuilder] = []
    private var deviceStack: [Int] = []
    private var currentService: [String: String]?
    private var text = ""

    private init(baseURL: URL) {
        self.baseURL = baseURL
    }

    static func parse(_ data: Data, baseURL: URL) -> UPnPDeviceDescription? {
        let delegate = UPnPDescriptionParser(baseURL: baseURL)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.result()
    }

    private func result() -> UPnPDeviceDescription? {
        let base = urlBase ?? baseURL
        let built = devices.compactMap { builder -> UPnPDeviceDescription? in
            guard let type = builder.fields["deviceType"], let udn = builder.fields["UDN"] else { return nil }
            let services = builder.services.compactMap { item -> UPnPDeviceDescription.Service? in
                guard let url = URL(string: item.control, relativeTo: base)?.absoluteURL else { return nil }
                return UPnPDeviceDescription.Service(serviceType: item.type, controlURL: url)
            }
            return UPnPDeviceDescription(
                deviceType: type,
                friendlyName: builder.fields["friendlyName"] ?? "",
                manufacturer: builder.fields["manufacturer"],
                modelName: builder.fields["modelName"],
                modelNumber: builder.fields["modelNumber"],
                udn: udn.replacingOccurrences(of: "uuid:", with: ""),
                services: services
            )
        }
        return built.first { $0.isMediaRenderer } ?? built.first
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        stack.append(elementName)
        text = ""
        if elementName == "device" {
            devices.append(DeviceBuilder())
            deviceStack.append(devices.count - 1)
        } else if elementName == "service" {
            currentService = [:]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            stack.removeLast()
            text = ""
        }
        if elementName == "URLBase", !value.isEmpty {
            urlBase = URL(string: value)
            return
        }
        if elementName == "device" {
            deviceStack.removeLast()
            return
        }
        if elementName == "service", let service = currentService, let index = deviceStack.last {
            if let type = service["serviceType"], let control = service["controlURL"] {
                devices[index].services.append((type, control))
            }
            currentService = nil
            return
        }
        if currentService != nil {
            currentService?[elementName] = value
            return
        }
        // Direct child of the current <device>.
        if let index = deviceStack.last, stack.count >= 2, stack[stack.count - 2] == "device", !value.isEmpty {
            devices[index].fields[elementName] = value
        }
    }
}
