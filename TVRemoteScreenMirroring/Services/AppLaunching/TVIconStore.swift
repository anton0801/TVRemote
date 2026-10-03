import CryptoKit
import Foundation
import Observation
import UIKit

/// App icons provided by the connected TV (LG launch points, Samsung `ed.apps.icon`).
/// Cached in memory and in Caches/tv-app-icons so the grid doesn't refetch on every launch.
@MainActor
@Observable
final class TVIconStore {
    private(set) var icons: [String: UIImage] = [:]
    private var inFlight: Set<String> = []
    /// Bumped when a TV is forgotten, so a download already in flight for it is dropped.
    private var epochs: [TVDeviceID: Int] = [:]
    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("tv-app-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func key(device: TVDeviceID, appID: String) -> String { "\(device.rawValue)|\(appID)" }

    func icon(device: TVDeviceID, appID: String) -> UIImage? {
        icons[Self.key(device: device, appID: appID)]
    }

    /// Loads the icon for an installed app once (disk cache first, then the TV).
    func load(_ app: TVAppInfo, device: TVDeviceID, session: any TVSession) {
        let key = Self.key(device: device, appID: app.id)
        guard icons[key] == nil, !inFlight.contains(key), app.iconURL != nil || app.iconPath != nil else { return }
        let file = directory.appendingPathComponent(Self.fileName(for: key))
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            icons[key] = image
            return
        }
        inFlight.insert(key)
        let epoch = epochs[device, default: 0]
        Task {
            defer { inFlight.remove(key) }
            guard let data = await session.appIconData(for: app), let image = UIImage(data: data) else { return }
            guard epochs[device, default: 0] == epoch else { return } // TV forgotten meanwhile
            icons[key] = image
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Removes cached icons of one TV (when it is forgotten); other TVs keep theirs.
    func clear(device: TVDeviceID) {
        epochs[device, default: 0] += 1
        let prefix = Self.hash(device.rawValue) + "-"
        icons = icons.filter { !$0.key.hasPrefix(device.rawValue + "|") }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Removes every cached icon.
    func clear() {
        icons.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// "<device hash>-<key hash>.png": files of one TV can be found without storing its ID.
    private static func fileName(for key: String) -> String {
        let device = key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? key
        return hash(device) + "-" + hash(key) + ".png"
    }
}
