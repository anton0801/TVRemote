import SwiftUI
import UIKit

/// Where a tile's artwork comes from, in priority order.
enum ServiceLogoSource: Equatable {
    /// Official brand asset added to the asset catalog by the owner (see BRAND_ASSETS.md).
    case bundled(String)
    /// Icon provided by the connected TV for the installed app.
    case tvIcon
    /// Neutral tile with the service name (asset not supplied yet / unknown app).
    case nameOnly

    /// Pure resolution rule (unit-tested).
    static func resolve(assetName: String?, assetExists: (String) -> Bool, hasTVIcon: Bool) -> ServiceLogoSource {
        if let assetName, assetExists(assetName) { return .bundled(assetName) }
        if hasTVIcon { return .tvIcon }
        return .nameOnly
    }
}

/// Artwork for a TV app: kit logo aspect-fit on a dark tile, the TV's own icon, or the name
/// in text (Apple TV is always text). Same outer geometry for every source.
struct ServiceLogoView: View {
    let title: String
    let assetName: String?
    let tvIcon: UIImage?
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        let source = ServiceLogoSource.resolve(assetName: assetName, assetExists: { UIImage(named: $0) != nil }, hasTVIcon: tvIcon != nil)
        let side = min(width, height)
        Group {
            switch source {
            case .bundled(let name):
                Image(name)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: side * 0.62, height: side * 0.62)
            case .tvIcon:
                if let tvIcon {
                    Image(uiImage: tvIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: side * 0.14, style: .continuous))
                        .frame(width: side * 0.7, height: side * 0.7)
                }
            case .nameOnly:
                Text(verbatim: title)
                    .font(.system(size: max(13, side * 0.2), weight: .bold))
                    .foregroundStyle(Color.appTextPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(side * 0.08)
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// Launch tile. The logo never implies the app is installed or subscribed — launch results are
/// still reported honestly. `.strip` = remote quick launch (caption under the tile),
/// `.card` = TV apps grid (caption inside the card, star for favorites).
struct AppTile: View {
    enum Layout { case strip, card }

    @Environment(AppModel.self) private var model
    let item: TVAppsController.Item
    var layout: Layout = .card
    @ScaledMetric(relativeTo: .caption) private var stripHeight: CGFloat = 58
    @ScaledMetric(relativeTo: .caption) private var cardHeight: CGFloat = 104

    private var isLaunching: Bool {
        if case .launching(let id) = model.apps.launchStatus { return id == item.id }
        return false
    }

    private var tvIcon: UIImage? {
        guard let deviceID = model.connection.state.deviceID, let appID = item.tvAppID else { return nil }
        return model.iconStore.icon(device: deviceID, appID: appID)
    }

    /// A tile that already shows the name as text (Apple TV, apps without a logo) has no caption.
    private var showsCaption: Bool {
        ServiceLogoSource.resolve(assetName: item.catalogEntry?.logoAssetName, assetExists: { UIImage(named: $0) != nil },
                                  hasTVIcon: tvIcon != nil) != .nameOnly
    }

    var body: some View {
        Button {
            guard model.remoteAllowed() else { return }
            Haptics.tap()
            model.apps.launch(item)
        } label: {
            switch layout {
            case .strip: strip
            case .card: card
            }
        }
        .buttonStyle(.plain)
        .disabled(isLaunching)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.tr("apps.open.accessibility", item.title))
        .accessibilityValue(model.apps.isFavorite(item) ? L10n.tr("apps.favorite.value") : "")
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button {
                model.apps.toggleFavorite(item)
            } label: {
                Label(model.apps.isFavorite(item) ? L10n.tr("apps.unfavorite", item.title) : L10n.tr("apps.favorite", item.title),
                      systemImage: model.apps.isFavorite(item) ? "star.slash" : "star")
            }
        }
        .task(id: item.tvAppID) {
            guard let app = item.tvApp, let session = model.connection.session, let deviceID = model.connection.state.deviceID else { return }
            model.iconStore.load(app, device: deviceID, session: session)
        }
    }

    private var strip: some View {
        VStack(spacing: 6) {
            tile(height: min(max(stripHeight, 52), 88)) { width, height in
                ServiceLogoView(title: item.title, assetName: item.catalogEntry?.logoAssetName, tvIcon: tvIcon, width: width, height: height)
            }
            Text(item.title)
                .font(.appCaption)
                .foregroundStyle(Color.appTextPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var card: some View {
        tile(height: min(max(cardHeight, 96), 150)) { width, height in
            VStack(spacing: Spacing.xs) {
                ServiceLogoView(title: item.title, assetName: item.catalogEntry?.logoAssetName, tvIcon: tvIcon,
                                width: width, height: showsCaption ? height * 0.62 : height * 0.8)
                if showsCaption {
                    Text(item.title)
                        .font(.appFootnote.weight(.medium))
                        .foregroundStyle(Color.appTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.xxs)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.apps.isFavorite(item) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(Color.appAccent)
                    .padding(Spacing.xs)
                    .accessibilityHidden(true)
            }
        }
    }

    private func tile<Content: View>(height: CGFloat, @ViewBuilder content: @escaping (CGFloat, CGFloat) -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        return GeometryReader { proxy in
            ZStack {
                content(proxy.size.width, proxy.size.height)
                if isLaunching {
                    shape.fill(.black.opacity(0.45))
                    ProgressView().tint(.white)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: height)
        .background(Color.appSurface, in: shape)
        .overlay(shape.stroke(Color.appBorder.opacity(0.8), lineWidth: 1))
        .clipShape(shape)
    }
}
