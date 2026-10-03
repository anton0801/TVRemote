import SwiftUI
import UIKit

/// Raster art from the design kit (`art-…` assets). Text, buttons and logos are never part of
/// the raster: service logos are native views placed over the art.
enum ArtAsset: String {
    case onboardingRemote = "art-onboarding-remote"
    case onboardingApps = "art-onboarding-apps"
    case onboardingCast = "art-onboarding-cast"
    case paywallHero = "art-paywall-hero"
    case connection = "art-connection"
    case connectionLost = "art-connection-lost"
    case noTV = "art-no-tv"
    case permission = "art-permission"
    case pending = "art-pending"
    case success = "art-success"
    case gift = "art-gift"
    case proBanner = "art-pro-banner"
}

/// Onboarding illustration (4:3). The apps page gets real service logos on top, positioned
/// per `handoff/onboarding-layout.json` relative to the displayed image rectangle.
struct OnboardingArt: View {
    let art: ArtAsset

    private struct Tile { let brand: String; let name: String; let cx: CGFloat; let cy: CGFloat }
    private static let tiles = [
        Tile(brand: "brand-netflix", name: "Netflix", cx: 0.24, cy: 0.74),
        Tile(brand: "brand-youtube", name: "YouTube", cx: 0.43, cy: 0.63),
        Tile(brand: "brand-disneyplus", name: "Disney+", cx: 0.63, cy: 0.53),
        Tile(brand: "brand-primevideo", name: "Prime Video", cx: 0.82, cy: 0.42),
    ]
    private static let tileWidth: CGFloat = 0.18

    var body: some View {
        Image(art.rawValue)
            .resizable()
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                if art == .onboardingApps {
                    GeometryReader { proxy in
                        let side = proxy.size.width * Self.tileWidth
                        ForEach(Self.tiles, id: \.brand) { tile in
                            BrandTile(asset: tile.brand, name: tile.name, side: side)
                                .rotationEffect(.degrees(-12))
                                .position(x: proxy.size.width * tile.cx, y: proxy.size.height * tile.cy)
                        }
                    }
                }
            }
            .accessibilityHidden(true)
    }
}

/// Logo tile used over the onboarding art: dark fill, warm border, logo aspect-fit.
struct BrandTile: View {
    let asset: String
    let name: String
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.2, style: .continuous)
        ZStack {
            shape.fill(Color.appSurface)
            if UIImage(named: asset) != nil {
                Image(asset)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(side * 0.16)
            } else {
                Text(verbatim: name)
                    .font(.system(size: side * 0.16, weight: .bold))
                    .foregroundStyle(Color.appTextPrimary)
                    .multilineTextAlignment(.center)
                    .padding(side * 0.08)
            }
        }
        .frame(width: side, height: side)
        .overlay(shape.stroke(Color(Palette.RGB(hex: 0x8E6B3F)), lineWidth: max(1, side * 0.02)))
        .shadow(color: .black.opacity(0.55), radius: side * 0.12, y: side * 0.06)
        .shadow(color: Color.appAccent.opacity(0.18), radius: side * 0.1)
    }
}
