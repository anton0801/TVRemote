import Foundation
import Observation

/// Finds TVs on the local network and reports incremental results.
///
/// Sources, in order of cost:
/// 1. Bonjour (`_androidtvremote2._tcp`, `_airplay._tcp`) — declared service types only.
/// 2. Saved TVs' last known addresses (fast reconnect / IP-change detection).
/// 3. SSDP multicast — only effective with the multicast entitlement.
/// 4. Bounded unicast probe of the /24 subnet for Samsung (8001) and LG (3000/3001).
/// Every result is keyed by a stable protocol identity; duplicates from several sources merge.
@MainActor
@Observable
final class DiscoveryService {
    enum Phase: Equatable {
        case idle
        case searching
        case finished
        case failed(AppError)
    }

    private(set) var phase: Phase = .idle
    private(set) var results: [DiscoveredTV] = []
    /// Fraction of the subnet probe completed (0…1).
    private(set) var probeProgress: Double = 0
    /// True when a multicast send was refused (entitlement not granted).
    private(set) var multicastUnavailable = false
    private(set) var permissionDenied = false

    private var runTask: Task<Void, Never>?
    /// Each run gets a new generation; a cancelled older run can't finish (or feed) the new one.
    private var generation = 0
    private var browser: BonjourBrowser?
    private let analytics: AnalyticsService?

    init(analytics: AnalyticsService? = nil) {
        self.analytics = analytics
    }

    var isSearching: Bool { phase == .searching }

    /// Starts a new discovery run. `knownDevices` are probed first at their last address.
    func start(knownDevices: [TVDevice], timeout: TimeInterval = 20) {
        stop()
        results = []
        probeProgress = 0
        permissionDenied = false
        guard let network = LocalNetworkInfo.current(), network.isPrivate else {
            phase = .failed(.noWiFi)
            DiagnosticsLog.shared.record(.discoveryNoWiFi)
            return
        }
        phase = .searching
        DiagnosticsLog.shared.record(.discoveryStarted)
        analytics?.log(.discoveryStarted)
        generation += 1
        let run = generation

        let browser = BonjourBrowser()
        self.browser = browser
        browser.start()

        runTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self?.consumeBonjour(browser) }
                group.addTask { await self?.probeKnown(knownDevices) }
                group.addTask { await self?.searchSSDP() }
                group.addTask { await self?.probeSubnet(network, skipping: Set(knownDevices.map(\.host))) }
                group.addTask {
                    try? await Task.sleep(for: .seconds(timeout))
                    browser.stop()
                }
                await group.waitForAll()
            }
            guard !Task.isCancelled, self?.generation == run else { return }
            self?.finish()
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        browser?.stop()
        browser = nil
        if phase == .searching { phase = .finished }
    }

    // MARK: Results

    /// Used by the running search's sources: results of a cancelled (restarted) run are dropped.
    private func mergeIfCurrent(_ tv: DiscoveredTV) {
        guard !Task.isCancelled else { return }
        merge(tv)
    }

    func merge(_ tv: DiscoveredTV) {
        if let index = results.firstIndex(where: { $0.id == tv.id }) {
            results[index].merge(tv)
        } else if let index = results.firstIndex(where: { $0.host == tv.host && ($0.platform == .unknown || tv.platform == .unknown) }) {
            // Same address seen by an AirPlay-only record and a protocol probe: keep the protocol identity.
            var merged = tv.platform == .unknown ? results[index] : tv
            merged.merge(tv.platform == .unknown ? tv : results[index])
            results[index] = merged
        } else {
            results.append(tv)
        }
        results.sort { lhs, rhs in
            if (lhs.platform == .unknown) != (rhs.platform == .unknown) { return rhs.platform == .unknown }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func finish() {
        guard phase == .searching else { return }
        browser?.stop()
        browser = nil
        if permissionDenied && results.isEmpty {
            phase = .failed(.localNetworkDenied)
            DiagnosticsLog.shared.record(.discoveryPermissionDenied)
        } else {
            phase = .finished
        }
        DiagnosticsLog.shared.record(.discoveryFinished)
        analytics?.log(.discoveryCompleted(found: results.filter { $0.platform != .unknown }.count, permissionDenied: permissionDenied))
    }

    // MARK: Sources

    private func consumeBonjour(_ browser: BonjourBrowser) async {
        for await event in browser.events {
            switch event {
            case .found(let record):
                if let tv = await Self.discovered(from: record) { mergeIfCurrent(tv) }
            case .permissionDenied:
                permissionDenied = true
            case .failed:
                break
            }
        }
    }

    private static func discovered(from record: BonjourBrowser.Record) async -> DiscoveredTV? {
        switch record.serviceType {
        case BonjourBrowser.androidTV:
            // `bt` carries a hardware address on many models; otherwise the service name is unique on the LAN.
            let unique = record.txt["bt"].flatMap { $0.isEmpty ? nil : $0 } ?? record.name
            return DiscoveredTV(
                id: TVDeviceID(platform: .androidTV, uniqueID: unique),
                platform: .androidTV,
                name: record.name,
                manufacturer: nil, modelName: nil, osVersion: nil,
                // `bt` is the Bluetooth address — useless for Wake-on-LAN, so it isn't stored as MAC.
                host: record.host, port: record.port, macAddress: nil,
                mediaRendererLocation: nil, sources: [.bonjour], advertisesAirPlay: false, lastSeen: .now
            )
        case BonjourBrowser.airPlay:
            let manufacturer = (record.txt["manufacturer"] ?? "").lowercased()
            // Probe Samsung/LG AirPlay receivers for their remote protocol identity.
            if manufacturer.contains("samsung"), let samsung = await TVProber.probeSamsung(host: record.host) {
                var tv = samsung
                tv.advertisesAirPlay = true
                tv.sources.insert(.bonjour)
                return tv
            }
            if manufacturer.hasPrefix("lg"), let lg = await TVProber.probeLG(host: record.host) {
                var tv = lg
                tv.advertisesAirPlay = true
                tv.sources.insert(.bonjour)
                return tv
            }
            // AirPlay-only TVs have no remote protocol we support; they are not listed.
            return nil
        default:
            return nil
        }
    }

    private func probeKnown(_ devices: [TVDevice]) async {
        await withTaskGroup(of: DiscoveredTV?.self) { group in
            for device in devices where device.platform != .androidTV {
                group.addTask {
                    switch device.platform {
                    case .samsungTizen: await TVProber.probeSamsung(host: device.host)
                    case .lgWebOS: await TVProber.probeLG(host: device.host)
                    default: nil
                    }
                }
            }
            for await result in group {
                if let result { mergeIfCurrent(result) }
            }
        }
    }

    private func searchSSDP() async {
        let result = await SSDPClient().search([.samsungRemote, .lgSecondScreen, .mediaRenderer], host: nil, timeout: 3)
        if result.multicastBlocked {
            multicastUnavailable = true
            return
        }
        let hosts = Set(result.responses.map(\.host))
        await withTaskGroup(of: DiscoveredTV?.self) { group in
            for host in hosts {
                group.addTask { await TVProber.probeAny(host: host) }
            }
            for await tv in group {
                if let tv { mergeIfCurrent(tv) }
            }
        }
    }

    private func probeSubnet(_ network: LocalNetworkInfo, skipping: Set<String>) async {
        let hosts = network.scanCandidates().filter { !skipping.contains($0) }
        guard !hosts.isEmpty else { probeProgress = 1; return }
        let concurrency = 32
        var completed = 0
        await withTaskGroup(of: DiscoveredTV?.self) { group in
            var iterator = hosts.makeIterator()
            for _ in 0..<concurrency {
                guard let host = iterator.next() else { break }
                group.addTask { await TVProber.probeAny(host: host) }
            }
            while let result = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                completed += 1
                probeProgress = Double(completed) / Double(hosts.count)
                if let result { mergeIfCurrent(result) }
                if let host = iterator.next() {
                    group.addTask { await TVProber.probeAny(host: host) }
                }
            }
        }
    }
}
