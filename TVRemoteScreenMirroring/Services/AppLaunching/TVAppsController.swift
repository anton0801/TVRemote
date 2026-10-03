import Foundation
import Observation

/// Quick-launch buttons and the full app list for the connected TV.
@MainActor
@Observable
final class TVAppsController {
    struct Item: Identifiable, Hashable {
        enum Availability: Hashable {
            /// Reported by the TV as installed.
            case installed
            /// Part of our catalog; the TV could not report installed apps.
            case catalog
        }

        let id: String
        let title: String
        let availability: Availability
        let catalogEntry: TVAppCatalog.Entry?
        /// App as reported by the TV (installed apps), including its icon source.
        let tvApp: TVAppInfo?

        var tvAppID: String? { tvApp?.id }
    }

    enum LaunchStatus: Equatable {
        case idle
        case launching(String)
        /// TV reported the app in the foreground.
        case opened(String)
        /// Command accepted; opening not confirmed by the TV.
        case sent(String)
        case failed(String, AppError)
    }

    private(set) var launchStatus: LaunchStatus = .idle
    private let connection: ConnectionManager
    private let devices: DeviceStore
    private let checker: CompatibilityChecker
    private let analytics: AnalyticsService

    init(connection: ConnectionManager, devices: DeviceStore, checker: CompatibilityChecker, analytics: AnalyticsService) {
        self.connection = connection
        self.devices = devices
        self.checker = checker
        self.analytics = analytics
    }

    /// True when the list is our catalog rather than what the TV reports.
    var isCatalog: Bool { checker.installedApps == nil }

    var items: [Item] {
        guard let platform = connection.session?.platform else { return [] }
        if let installed = checker.installedApps {
            // Known services first (matched by platform ID), then everything else alphabetically.
            var known: [Item] = []
            var others: [Item] = []
            for app in installed {
                if let entry = TVAppCatalog.entry(matching: app.id, platform: platform) {
                    if !known.contains(where: { $0.id == entry.id }) {
                        known.append(Item(id: entry.id, title: entry.displayName, availability: .installed, catalogEntry: entry, tvApp: app))
                    }
                } else {
                    others.append(Item(id: "tv:\(app.id)", title: app.title, availability: .installed, catalogEntry: nil, tvApp: app))
                }
            }
            known.sort { lhs, rhs in
                (TVAppCatalog.all.firstIndex { $0.id == lhs.id } ?? 0) < (TVAppCatalog.all.firstIndex { $0.id == rhs.id } ?? 0)
            }
            return known + others.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return TVAppCatalog.all.map { Item(id: $0.id, title: $0.displayName, availability: .catalog, catalogEntry: $0, tvApp: nil) }
    }

    var favoriteIDs: [String] {
        guard let id = connection.state.deviceID else { return TVAppCatalog.defaultFavoriteIDs }
        return devices.favorites(for: id) ?? TVAppCatalog.defaultFavoriteIDs
    }

    var favorites: [Item] {
        let all = items
        return favoriteIDs.compactMap { id in all.first { $0.id == id } }
    }

    func isFavorite(_ item: Item) -> Bool { favoriteIDs.contains(item.id) }

    func toggleFavorite(_ item: Item) {
        guard let deviceID = connection.state.deviceID else { return }
        var ids = favoriteIDs
        if let index = ids.firstIndex(of: item.id) { ids.remove(at: index) } else { ids.append(item.id) }
        devices.setFavorites(ids, for: deviceID)
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        guard let deviceID = connection.state.deviceID else { return }
        var ids = favoriteIDs
        ids.move(fromOffsets: source, toOffset: destination)
        devices.setFavorites(ids, for: deviceID)
    }

    func launch(_ item: Item) {
        guard let session = connection.session else {
            launchStatus = .failed(item.id, .connectionLost)
            return
        }
        let sessionID = connection.sessionID
        launchStatus = .launching(item.id)
        DiagnosticsLog.shared.record(.appLaunchSent, platform: session.platform)
        Task {
            do {
                let outcome: AppLaunchOutcome
                if let tvAppID = item.tvAppID {
                    outcome = try await session.launch(appID: tvAppID)
                } else if let entry = item.catalogEntry {
                    outcome = try await session.launch(entry)
                } else {
                    throw AppError.appNotInstalled
                }
                guard sessionID == connection.sessionID else { return }
                switch outcome {
                case .confirmedForeground:
                    launchStatus = .opened(item.id)
                    DiagnosticsLog.shared.record(.appLaunchConfirmed, platform: session.platform)
                    analytics.log(.tvAppLaunchResult(platform: session.platform, appID: item.catalogEntry?.id ?? "other", result: .success))
                case .accepted:
                    launchStatus = .sent(item.id)
                    analytics.log(.tvAppLaunchResult(platform: session.platform, appID: item.catalogEntry?.id ?? "other", result: .unconfirmed))
                }
            } catch {
                guard sessionID == connection.sessionID else { return }
                let appError = AppError.wrap(error)
                let mapped: AppError = appError == .commandNotSupported ? .appLaunchFailed : appError
                launchStatus = .failed(item.id, mapped)
                DiagnosticsLog.shared.record(.appLaunchFailed, platform: session.platform, error: mapped)
                analytics.log(.tvAppLaunchResult(platform: session.platform, appID: item.catalogEntry?.id ?? "other", result: .failure))
            }
            try? await Task.sleep(for: .seconds(4))
            if case .launching = launchStatus { return }
            launchStatus = .idle
        }
    }
}
