import SwiftUI

/// Semantic type scale (design kit v2: hero 32, title 28 bold, section 20 semibold,
/// body/button 17, caption 13). Every style is a Dynamic Type text style, so it scales with
/// the user's text size; nothing is squeezed with `minimumScaleFactor`.
///
/// | Role                                   | Style (default size)        |
/// |----------------------------------------|-----------------------------|
/// | Onboarding / paywall hero              | largeTitle, bold (34)       |
/// | Screen title                           | title, bold (28)            |
/// | State title, banner, section title     | title3, semibold (20)       |
/// | Row title emphasis, plan name          | headline (17 semibold)      |
/// | Body, rows, fields                     | body (17)                   |
/// | Primary button                         | headline (17 semibold)      |
/// | Row subtitle, hints                    | subheadline (15)            |
/// | Captions, status lines, footers        | footnote (13)               |
/// | Key captions, tab-like labels          | caption, medium (12)        |
/// | Fine print under purchase CTA          | caption2 (11)               |
extension Font {
    static let appHeroTitle = Font.largeTitle.weight(.bold)
    static let appScreenTitle = Font.title.weight(.bold)
    static let appBannerTitle = Font.title3.weight(.semibold)
    static let appPlanTitle = Font.headline
    /// Emphasized row / card title.
    static let appHeadline = Font.headline
    /// Title of a state view or a screen section.
    static let appSectionTitle = Font.title3.weight(.semibold)
    static let appPrice = Font.title3.weight(.bold)
    static let appBody = Font.body
    static let appBodyEmphasis = Font.body.weight(.medium)
    static let appButton = Font.headline
    static let appSecondary = Font.subheadline
    static let appFootnote = Font.footnote
    static let appCaption = Font.caption.weight(.medium)
    /// Uppercase group header in grouped lists ("APPLICATION", "YOUR PLAN").
    static let appSectionLabel = Font.footnote.weight(.semibold)
    /// Fine print under a purchase button (caption2, 11 pt — the smallest system text style).
    static let appFinePrint = Font.caption2
}
