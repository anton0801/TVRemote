import Foundation

/// Built-in catalog of streaming apps with per-platform identifiers.
///
/// Identifiers come from public protocol libraries (see COMPATIBILITY.md) and differ by model
/// year and region, so several candidates are listed and tried in order. When a TV cannot
/// report installed apps, the UI labels this list as a *catalog*, not as installed apps.
/// Service names are trademarks of their owners and are shown as plain text buttons.
enum TVAppCatalog {
    struct Entry: Identifiable, Hashable, Sendable {
        let id: String
        let displayName: String
        let samsungIDs: [String]
        let lgIDs: [String]
        /// App links for Android TV (`remote_app_link_launch_request`).
        let androidLinks: [String]
        /// Package names used to confirm the foreground app on Android TV.
        let androidPackages: [String]

        func identifiers(for platform: TVPlatform) -> [String] {
            switch platform {
            case .samsungTizen: samsungIDs
            case .lgWebOS: lgIDs
            case .androidTV: androidPackages
            case .unknown: []
            }
        }

        /// Asset-catalog logo from the design kit (`brand-…`, sources in BRAND_ASSETS.md). Apple TV
        /// has none on purpose: it is shown as the service name in text.
        var logoAssetName: String { "brand-\(id)" }

        func matches(appID: String, platform: TVPlatform) -> Bool {
            identifiers(for: platform).contains { $0.caseInsensitiveCompare(appID) == .orderedSame }
        }
    }

    static let netflix = Entry(
        id: "netflix", displayName: "Netflix",
        samsungIDs: ["3201907018807", "11101200001"],
        lgIDs: ["netflix"],
        androidLinks: ["netflix://", "market://launch?id=com.netflix.ninja"],
        androidPackages: ["com.netflix.ninja"]
    )

    static let youtube = Entry(
        id: "youtube", displayName: "YouTube",
        samsungIDs: ["111299001912"],
        lgIDs: ["youtube.leanback.v4"],
        androidLinks: ["https://www.youtube.com"],
        androidPackages: ["com.google.android.youtube.tv"]
    )

    static let primeVideo = Entry(
        id: "primevideo", displayName: "Prime Video",
        samsungIDs: ["3201910019365", "3201512006785"],
        lgIDs: ["amazon"],
        androidLinks: ["https://app.primevideo.com"],
        androidPackages: ["com.amazon.amazonvideo.livingroom"]
    )

    static let disneyPlus = Entry(
        id: "disneyplus", displayName: "Disney+",
        samsungIDs: ["3202204027038", "3202009021709", "3201901017640"],
        lgIDs: ["com.disney.disneyplus-prod"],
        androidLinks: ["https://www.disneyplus.com"],
        androidPackages: ["com.disney.disneyplus"]
    )

    static let appleTV = Entry(
        id: "appletv", displayName: "Apple TV",
        samsungIDs: ["3201807016597"],
        lgIDs: ["com.apple.appletv"],
        androidLinks: ["https://tv.apple.com"],
        androidPackages: ["com.apple.atve.androidtv.appletv", "com.apple.atve.sony.appletv"]
    )

    static let spotify = Entry(
        id: "spotify", displayName: "Spotify",
        samsungIDs: ["3201606009684"],
        lgIDs: ["spotify-beehive"],
        androidLinks: ["spotify://", "market://launch?id=com.spotify.tv.android"],
        androidPackages: ["com.spotify.tv.android"]
    )

    static let all: [Entry] = [netflix, youtube, disneyPlus, primeVideo, spotify, appleTV]

    static func entry(id: String) -> Entry? { all.first { $0.id == id } }

    /// Catalog entry corresponding to an installed app reported by the TV, if any.
    static func entry(matching appID: String, platform: TVPlatform) -> Entry? {
        all.first { $0.matches(appID: appID, platform: platform) }
    }

    /// Default quick buttons before the user customizes favorites.
    static let defaultFavoriteIDs = ["netflix", "youtube", "disneyplus", "primevideo"]

    /// Browser identifiers used to open the mirroring receiver page.
    static let samsungBrowserIDs = ["org.tizen.browser", "3202010022079", "3201907018784"]
}
