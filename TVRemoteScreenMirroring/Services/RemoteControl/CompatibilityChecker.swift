import Foundation
import Observation

/// Runs real, per-TV capability checks after a connection. Results are evidence-based:
/// "supported" means the protocol/device answered, never "the brand usually supports it".
@MainActor
@Observable
final class CompatibilityChecker {
    enum Phase: Equatable { case idle, running, finished }

    private(set) var phase: Phase = .idle
    private(set) var deviceID: TVDeviceID?
    private(set) var capabilities = TVCapabilities()
    private(set) var installedApps: [TVAppInfo]?
    private(set) var renderer: MediaRendererController?

    private let devices: DeviceStore
    private let analytics: AnalyticsService
    private var task: Task<Void, Never>?

    init(devices: DeviceStore, analytics: AnalyticsService) {
        self.devices = devices
        self.analytics = analytics
    }

    func run(for device: TVDevice, session: any TVSession) {
        task?.cancel()
        deviceID = device.id
        phase = .running
        installedApps = nil
        renderer = nil
        var result = TVCapabilities()
        result[.remoteControl] = session.supportedCommands.isEmpty ? .unsupported([.protocolUnsupported]) : .supported(
            session.supportedCommands.contains(where: { session.supportsPressRelease($0) }) ? [] : [.holdNotSupported]
        )
        switch session.textInputMode {
        case .appendAndDelete?: result[.textInput] = .supported([.textNeedsFocusedField])
        case .replaceField?: result[.textInput] = .supported([.textNeedsFocusedField, .textReplaceOnly])
        case .sendCompleted?: result[.textInput] = .supported([.textNeedsFocusedField, .textReplaceOnly])
        case nil: result[.textInput] = .unsupported([.protocolUnsupported])
        }
        result[.powerOff] = session.supportedCommands.contains(.powerOff) || session.supportedCommands.contains(.powerToggle)
            ? .supported() : .unsupported([.protocolUnsupported])
        result[.wakeOnNetwork] = device.macAddress == nil
            ? .unsupported([.wakeNeedsMacAddress])
            : CapabilityState(support: .limited, notes: [.wakeNeedsMulticastEntitlement, .wakeNeedsTVSetting], checkedAt: .now)
        if session.canOpenBrowser {
            result[.screenMirroring] = CapabilityState(support: .limited, notes: [.mirroringNeedsBrowser, .mirroringVideoOnlyNoAudio], checkedAt: .now)
        } else {
            result[.screenMirroring] = .unsupported([.mirroringNoBrowserOnPlatform])
        }
        capabilities = result

        let deviceID = device.id
        task = Task { [weak self] in
            // Apps
            var apps: TVCapabilities = TVCapabilities()
            if session.canListInstalledApps, let list = try? await session.installedApps(), !list.isEmpty {
                apps[.appLaunch] = .supported()
                // Only for the TV this check was started for (the user may have switched).
                if let self, !Task.isCancelled, self.deviceID == deviceID { self.installedApps = list }
            } else {
                apps[.appLaunch] = .supported([.appListIsCatalog, .appLaunchUnconfirmed])
            }
            guard let self, !Task.isCancelled, self.deviceID == deviceID else { return }
            self.capabilities.merge(apps)

            // Media renderer (photos / video)
            var media = TVCapabilities()
            if let controller = await MediaRendererController.locate(host: device.host, knownLocation: device.mediaRendererLocation) {
                // A slow lookup for the previous TV must never attach its renderer to the new one.
                guard !Task.isCancelled, self.deviceID == deviceID else { return }
                self.renderer = controller
                let sink = await controller.sinkSupport()
                media[.photos] = sink.jpeg ? .supported(sink.reported ? [] : [.videoFormatLimited]) : .unsupported([.noMediaRenderer])
                media[.video] = sink.mp4 ? .supported([.videoFormatLimited]) : .unsupported([.videoFormatLimited])
            } else {
                media[.photos] = .unsupported([.noMediaRenderer])
                media[.video] = .unsupported([.noMediaRenderer])
            }
            guard !Task.isCancelled, self.deviceID == deviceID else { return }
            self.capabilities.merge(media)
            self.devices.updateCapabilities(for: deviceID, self.capabilities)
            self.phase = .finished
            self.analytics.log(.capabilityCheckCompleted(platform: device.platform, usableCount: self.capabilities.usableCount))
        }
    }

    /// Records a confirmed mirroring result (first frame acknowledged by the TV).
    func confirmMirroring(for id: TVDeviceID) {
        var update = TVCapabilities()
        update[.screenMirroring] = CapabilityState(support: .limited, notes: [.mirroringNeedsBrowser, .mirroringVideoOnlyNoAudio], checkedAt: .now)
        devices.updateCapabilities(for: id, update)
        if deviceID == id { capabilities.merge(update) }
    }

    func reset() {
        task?.cancel()
        phase = .idle
        deviceID = nil
        installedApps = nil
        renderer = nil
        capabilities = TVCapabilities()
    }
}
