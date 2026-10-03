import Foundation
import Observation

/// Saved TVs, favorites and the current selection. Survives entitlement expiry.
@MainActor
@Observable
final class DeviceStore {
    private(set) var devices: [TVDevice] = []
    private(set) var selectedDeviceID: TVDeviceID?
    /// Favorite quick-launch app IDs per TV, in user order.
    private(set) var favoriteApps: [TVDeviceID: [String]] = [:]

    private struct Snapshot: Codable {
        var devices: [TVDevice]
        var selectedDeviceID: TVDeviceID?
        var favoriteApps: [String: [String]]
    }

    private let store: JSONFileStore<Snapshot>
    private let credentials: CredentialStore

    init(fileName: String = "devices.json", credentials: CredentialStore = CredentialStore()) {
        store = JSONFileStore(fileName: fileName)
        self.credentials = credentials
        if let snapshot = store.load() {
            devices = snapshot.devices
            selectedDeviceID = snapshot.selectedDeviceID
            favoriteApps = Dictionary(uniqueKeysWithValues: snapshot.favoriteApps.map { (TVDeviceID(rawValue: $0.key), $0.value) })
        }
    }

    var selectedDevice: TVDevice? {
        guard let selectedDeviceID else { return nil }
        return devices.first { $0.id == selectedDeviceID }
    }

    func device(_ id: TVDeviceID) -> TVDevice? {
        devices.first { $0.id == id }
    }

    /// Inserts or updates a TV. Existing user-chosen name and favorites are preserved.
    func upsert(_ device: TVDevice) {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            var merged = device
            merged.customName = devices[index].customName
            merged.addedAt = devices[index].addedAt
            devices[index] = merged
        } else {
            devices.append(device)
        }
        persist()
    }

    /// Updates only the network route of a known TV after re-discovery (IP change).
    func updateRoute(for id: TVDeviceID, host: String, mediaRendererLocation: URL?) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].host = host
        if let mediaRendererLocation { devices[index].mediaRendererLocation = mediaRendererLocation }
        persist()
    }

    func updateCapabilities(for id: TVDeviceID, _ capabilities: TVCapabilities) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].capabilities.merge(capabilities)
        persist()
    }

    func markConnected(_ id: TVDeviceID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].lastConnectedAt = .now
        persist()
    }

    func rename(_ id: TVDeviceID, to name: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        devices[index].customName = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
        persist()
    }

    func select(_ id: TVDeviceID?) {
        selectedDeviceID = id
        persist()
    }

    /// Forget a TV: removes local data and pairing credentials.
    func forget(_ id: TVDeviceID) {
        devices.removeAll { $0.id == id }
        favoriteApps[id] = nil
        credentials.remove(for: id)
        if selectedDeviceID == id { selectedDeviceID = devices.first?.id }
        persist()
    }

    func favorites(for id: TVDeviceID) -> [String]? {
        favoriteApps[id]
    }

    func setFavorites(_ appIDs: [String], for id: TVDeviceID) {
        favoriteApps[id] = appIDs
        persist()
    }

    private func persist() {
        store.save(Snapshot(
            devices: devices,
            selectedDeviceID: selectedDeviceID,
            favoriteApps: Dictionary(uniqueKeysWithValues: favoriteApps.map { ($0.key.rawValue, $0.value) })
        ))
    }
}
