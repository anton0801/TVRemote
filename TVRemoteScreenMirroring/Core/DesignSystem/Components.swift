import SwiftUI
import UIKit

// MARK: - Icons

extension Image {
    /// A design-kit icon (`icon-…` asset, template vector) or an SF Symbol name.
    static func app(_ name: String) -> Image {
        name.hasPrefix("icon-") ? Image(name).renderingMode(.template) : Image(systemName: name)
    }
}

/// Kit icon at a size that follows Dynamic Type (kit icons are vectors, not font glyphs).
struct AppIconView: View {
    let name: String
    @ScaledMetric private var size: CGFloat

    init(_ name: String, size: CGFloat = 24, relativeTo style: Font.TextStyle = .body) {
        self.name = name
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
    }

    var body: some View {
        Group {
            if name.hasPrefix("icon-") {
                Image(name).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: name).resizable().aspectRatio(contentMode: .fit).fontWeight(.medium)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Icon inside a small dark tile (rows with toggles, notification types, privacy).
struct IconTile: View {
    let name: String
    var tint: Color = .appAccent
    var size: CGFloat = 40

    var body: some View {
        AppIconView(name, size: size * 0.55)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Buttons

/// Amber filled button, 56 pt. Icons may be added with `Label`.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ButtonLabelStyle())
            .font(.appButton)
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.appOnAccent)
            .frame(maxWidth: .infinity, minHeight: HitTarget.primaryButton)
            .padding(.horizontal, Spacing.m)
            .background(Color.appAccentFill.opacity(isEnabled ? 1 : 0.45), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

/// Dark surface button with a hairline border ("Show a new code", "Connection help").
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ButtonLabelStyle())
            .font(.appBodyEmphasis)
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.appTextPrimary.opacity(isEnabled ? 1 : 0.4))
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, Spacing.m)
            .background(configuration.isPressed ? Color.appSurfaceRaised : Color.appSurface,
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Color.appBorder, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

/// Amber outline ("Request again", "Add a TV", "Stop casting").
struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ButtonLabelStyle())
            .font(.appButton)
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.appAccent.opacity(isEnabled ? 1 : 0.45))
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.horizontal, Spacing.m)
            .background(Color.appAccent.opacity(configuration.isPressed ? 0.16 : 0.07),
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .stroke(Color.appAccent.opacity(isEnabled ? 0.85 : 0.35), lineWidth: 1.5))
            .contentShape(Rectangle())
    }
}

/// Red filled button for stopping an active session ("Stop sharing").
struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ButtonLabelStyle())
            .font(.appButton)
            .foregroundStyle(Color(Palette.onDangerFill))
            .frame(maxWidth: .infinity, minHeight: HitTarget.primaryButton)
            .padding(.horizontal, Spacing.m)
            .background(Color.appDangerFill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

struct TextActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(ButtonLabelStyle())
            .font(.appBodyEmphasis)
            .foregroundStyle(Color.appAccent)
            .frame(minHeight: HitTarget.minimum)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// Icon + title with the kit's spacing; kit icons are sized like the text.
private struct ButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.xs + 2) {
            configuration.icon
            configuration.title
        }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    static var outline: OutlineButtonStyle { OutlineButtonStyle() }
}

extension ButtonStyle where Self == DestructiveButtonStyle {
    static var destructive: DestructiveButtonStyle { DestructiveButtonStyle() }
}

extension ButtonStyle where Self == TextActionButtonStyle {
    static var textAction: TextActionButtonStyle { TextActionButtonStyle() }
}

/// Type-erased style for choosing a style at runtime.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<Style: ButtonStyle>(_ style: Style) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Button label with a kit icon, e.g. `Label { Text("Find my TV") } icon: { ButtonIcon("icon-search") }`.
struct ButtonIcon: View {
    let name: String
    init(_ name: String) { self.name = name }
    var body: some View { AppIconView(name, size: 22, relativeTo: .headline) }
}

// MARK: - Surfaces

struct SurfaceCardModifier: ViewModifier {
    var padding: CGFloat = Spacing.m
    var radius: CGFloat = Radius.card
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.appAccentTint : Color.appSurface,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(highlighted ? Color.appAccent.opacity(0.85) : Color.appBorder.opacity(0.7), lineWidth: highlighted ? 1.5 : 1)
            )
    }
}

extension View {
    func surfaceCard(padding: CGFloat = Spacing.m, radius: CGFloat = Radius.card, highlighted: Bool = false) -> some View {
        modifier(SurfaceCardModifier(padding: padding, radius: radius, highlighted: highlighted))
    }

    /// Standard screen background.
    func appScreenBackground() -> some View {
        background(Color.appBackground.ignoresSafeArea())
    }

    /// Opaque strip behind the status bar for screens without a navigation bar, so scrolled
    /// content never runs under the clock.
    func statusBarBackground() -> some View {
        overlay(alignment: .top) {
            Color.appBackground
                .frame(height: 0)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }
}

/// Large title of a tab's root screen with an optional trailing accessory (e.g. the PRO badge).
struct ScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.appHeroTitle)
                    .foregroundStyle(Color.appTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.appBody)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Big title at the top of a pushed screen's content (design: "‹ Back" above a large title).
/// Unlike the system large title it wraps instead of truncating long translations.
struct PageHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.appHeroTitle)
            .foregroundStyle(Color.appTextPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Navigation bar with only the back button; the title lives in the content (`PageHeader`).
    func pageNavigation(_ title: String) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
            }
    }
}

/// Amber "PRO" mark shown next to a title when Remote Pro is active.
struct ProBadge: View {
    var body: some View {
        Text(verbatim: "PRO")
            .font(.appHeadline.weight(.bold))
            .foregroundStyle(Color.appAccent)
            .accessibilityLabel(L10n.tr("pro.badge.accessibility"))
    }
}

// MARK: - Status

/// Colored dot + text. Status is never conveyed by color alone.
struct StatusBadge: View {
    enum Kind { case ready, attention, neutral, error }

    let kind: Kind
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            switch kind {
            case .ready: Circle().fill(Color.appSuccess).frame(width: 8, height: 8)
            case .neutral: Circle().fill(Color.appTextSecondary).frame(width: 8, height: 8)
            case .attention: AppIconView("icon-info", size: 16, relativeTo: .footnote).foregroundStyle(Color.appAccent)
            case .error: AppIconView("icon-warning", size: 16, relativeTo: .footnote).foregroundStyle(Color.appDanger)
            }
            Text(text)
                .font(.appFootnote)
                .foregroundStyle(Color.appTextSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// (i) + short secondary explanation.
struct InfoNote: View {
    let text: String
    var icon = "icon-info"
    var boxed = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            AppIconView(icon, size: 20, relativeTo: .footnote)
                .foregroundStyle(Color.appAccent)
            Text(text)
                .font(.appFootnote)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(boxed ? Spacing.m : 0)
        .background {
            if boxed {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.appSurface)
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Color.appBorder.opacity(0.7), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Numbered instruction: circled number, optional icon, title and detail.
struct NumberedStep: View {
    let number: Int
    var icon: String?
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            Text(verbatim: "\(number)")
                .font(.appHeadline)
                .foregroundStyle(Color.appAccent)
                .frame(width: 34, height: 34)
                .overlay(Circle().stroke(Color.appAccent, lineWidth: 1.5))
            if let icon {
                AppIconView(icon, size: 26).foregroundStyle(Color.appTextPrimary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                if let detail {
                    Text(detail).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Choice controls

/// Two- or three-option control with icons (Touchpad / Buttons).
struct ChoiceSegment<Value: Hashable>: View {
    let options: [(value: Value, title: String, icon: String)]
    @Binding var selection: Value
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Very large text: options stack instead of breaking words.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: Spacing.xs)) : AnyLayout(HStackLayout(spacing: Spacing.xs))
        layout {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    Haptics.selection()
                    selection = option.value
                } label: {
                    HStack(spacing: Spacing.xs) {
                        AppIconView(option.icon, size: 20, relativeTo: .subheadline)
                            .foregroundStyle(selected ? Color.appAccent : Color.appTextPrimary)
                        Text(option.title)
                            .font(.appSecondary.weight(.medium))
                            .foregroundStyle(selected ? Color.appAccent : Color.appTextPrimary)
                    }
                    .frame(maxWidth: .infinity, minHeight: HitTarget.minimum)
                    .background(selected ? Color.appAccentTint : Color.clear, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .stroke(selected ? Color.appAccent.opacity(0.85) : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(Spacing.xxs)
    }
}

/// Radio indicator for single-choice lists (plans, language, quality).
struct RadioIndicator: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle().stroke(isOn ? Color.appAccent : Color.appTextSecondary, lineWidth: 1.8)
            if isOn { Circle().fill(Color.appAccent).padding(5) }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

// MARK: - State views

/// Shared empty / error / permission / unsupported state. Always offers a way forward.
struct StateMessageView: View {
    var art: String?
    var systemImage: String = "info.circle"
    let title: String
    let message: String
    var primaryTitle: String?
    var primaryAction: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
    var tint: Color = .appAccent

    var body: some View {
        VStack(spacing: Spacing.m) {
            if let art {
                Image(art)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 240, maxHeight: 176)
                    .accessibilityHidden(true)
            } else {
                AppIconView(systemImage, size: 44, relativeTo: .title)
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.appScreenTitle)
                .foregroundStyle(Color.appTextPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.appBody)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let primaryTitle, let primaryAction {
                Button(primaryTitle, action: primaryAction)
                    .buttonStyle(.primary)
                    .padding(.top, Spacing.xs)
            }
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction)
                    .buttonStyle(.secondary)
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
    }
}

/// Progress with an explanation and an exit. No bare infinite spinner.
struct ProgressMessageView: View {
    let title: String
    var message: String?
    var cancelTitle: String?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(spacing: Spacing.m) {
            ProgressView()
                .controlSize(.large)
                .tint(.appAccent)
            Text(title)
                .font(.appHeadline)
                .foregroundStyle(Color.appTextPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.appSecondary)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
            }
            if let cancelTitle, let onCancel {
                Button(cancelTitle, action: onCancel)
                    .buttonStyle(.textAction)
            }
        }
        .padding(Spacing.xl)
        .accessibilityElement(children: .combine)
    }
}

/// Inline, dismissible message for recoverable errors.
struct InlineNoticeView: View {
    enum Kind { case info, warning, error, success }

    let kind: Kind
    let text: String
    var actionTitle: String?
    /// Single-line layout with the action on the trailing side (status banners).
    var compact = false
    var action: (() -> Void)?

    private var icon: String {
        switch kind {
        case .info: "icon-info"
        case .warning: "icon-warning"
        case .error: "icon-warning"
        case .success: "icon-check-circle"
        }
    }

    private var tint: Color {
        switch kind {
        case .info, .warning: .appAccent
        case .error: .appDanger
        case .success: .appSuccess
        }
    }

    var body: some View {
        if compact {
            compactBody
        } else {
            stackedBody
        }
    }

    private var compactBody: some View {
        HStack(spacing: Spacing.s) {
            AppIconView(icon, size: 20, relativeTo: .subheadline)
                .foregroundStyle(tint)
            Text(text)
                .font(.appSecondary)
                .foregroundStyle(Color.appTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.xs)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.appSecondary.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                    .frame(minHeight: HitTarget.minimum)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xxs)
        .background(background)
        .accessibilityElement(children: .combine)
    }

    private var stackedBody: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            AppIconView(icon, size: 22, relativeTo: .subheadline)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(text)
                    .font(.appSecondary)
                    .foregroundStyle(Color.appTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.appSecondary.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                        .frame(minHeight: HitTarget.minimum, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .background(background)
        .accessibilityElement(children: .combine)
    }

    private var background: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(kind == .warning ? Color.appAccentTint : Color.appSurface)
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .stroke(kind == .warning ? Color.appAccent.opacity(0.7) : Color.appBorder.opacity(0.7), lineWidth: 1)
        }
    }
}

/// Small heading above a group ("Quick launch", "Numbers").
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.appHeadline)
            .foregroundStyle(Color.appTextPrimary)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Haptics

@MainActor
enum Haptics {
    static var isEnabled = true

    static func tap() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func selection() {
        guard isEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
