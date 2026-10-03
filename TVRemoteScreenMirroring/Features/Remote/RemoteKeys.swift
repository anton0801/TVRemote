import SwiftUI

/// Accessible label and kit icon for every logical command.
extension RemoteCommand {
    var accessibilityLabel: String { L10n.tr("key.\(rawValue)") }

    /// Kit icon (`icon-…`) or SF Symbol for commands the kit has no icon for.
    var icon: String {
        switch self {
        case .up: "icon-chevron-up"
        case .down: "icon-chevron-down"
        case .left: "icon-chevron-left"
        case .right: "icon-chevron-right"
        case .back: "icon-back"
        case .home: "icon-home"
        case .menu: "icon-menu"
        case .settings: "icon-settings"
        case .info: "icon-info"
        case .guide: "list.bullet.rectangle"
        case .input: "icon-input"
        case .volumeUp, .channelUp: "icon-plus"
        case .volumeDown, .channelDown: "icon-minus"
        case .mute: "icon-mute"
        case .playPause: "icon-play-pause"
        case .play: "icon-play"
        case .pause: "icon-pause"
        case .stop: "icon-stop"
        case .rewind: "icon-rewind"
        case .fastForward: "icon-forward"
        case .next: "icon-next"
        case .previous: "icon-previous"
        case .powerOff, .powerToggle: "icon-power"
        default: "number"
        }
    }

    var digitText: String? {
        guard let index = RemoteCommand.digits.firstIndex(of: self) else { return nil }
        return "\((index + 1) % 10)"
    }
}

/// Look of a remote key. The gesture handling is the same for all of them.
enum KeyStyle {
    /// Dark rounded square (arrows, digits, media keys).
    case standard
    /// Amber filled square (OK).
    case prominent
    /// Icon over a caption ("Back", "Home", …).
    case captioned(String)
    /// Borderless glyph inside a grouped bar (volume/channel −/+).
    case bare
}

/// A remote key with immediate visual/haptic feedback. The feedback shows the *tap*, not a
/// confirmation that the TV executed the command.
struct RemoteKeyButton: View {
    let command: RemoteCommand
    var width: CGFloat? = nil
    var height: CGFloat = HitTarget.remoteKey
    var style: KeyStyle = .standard
    var labelOverride: String?
    let hold: KeyHoldController
    var isEnabled = true

    @State private var pressed = false
    /// Resets automatically when the gesture ends *or is cancelled* (e.g. the touch turns into
    /// a scroll or a sheet takes it) — `onEnded` alone is not called on cancellation.
    @GestureState private var isTouching = false
    /// The finger slid off the key (e.g. the user started scrolling the page): this touch no
    /// longer counts, like a standard iOS button.
    @State private var slidOff = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the finger may move from where it touched down before the press is cancelled.
    private static let slideOffDistance: CGFloat = 30

    var body: some View {
        content
            .frame(minWidth: width, maxWidth: width ?? .infinity, minHeight: height, maxHeight: height)
            .background(background)
            .scaleEffect(pressed && !reduceMotion ? 0.95 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: Motion.quick), value: pressed)
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isTouching) { _, touching, _ in touching = true }
                    .onChanged { value in
                        if pressed, hypot(value.translation.width, value.translation.height) > Self.slideOffDistance {
                            // Slid away: no tap is sent; a hold already running is released.
                            pressed = false
                            slidOff = true
                            hold.cancelAll()
                            return
                        }
                        guard isEnabled, !pressed, !slidOff else { return }
                        pressed = true
                        Haptics.tap()
                        hold.touchDown(command)
                    }
                    .onEnded { _ in
                        slidOff = false
                        guard pressed else { return }
                        pressed = false
                        hold.touchUp(command)
                    }
            )
            .onChange(of: isTouching) { _, touching in
                guard !touching else { return }
                slidOff = false
                // Cancelled without `onEnded`: release without sending an extra click.
                if pressed {
                    pressed = false
                    hold.cancelAll()
                }
            }
            .onDisappear {
                if pressed { pressed = false; hold.cancelAll() }
            }
            .accessibilityElement()
            .accessibilityLabel(labelOverride ?? command.accessibilityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                guard isEnabled else { return }
                hold.touchDown(command)
                hold.touchUp(command)
            }
    }

    @ViewBuilder
    private var content: some View {
        let tint: Color = {
            if case .prominent = style { return .appOnAccent }
            return .appTextPrimary
        }()
        if let digit = command.digitText {
            Text(verbatim: digit)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
        } else if command == .ok {
            Text(L10n.tr("key.ok.short"))
                .font(.appHeadline.weight(.bold))
                .foregroundStyle(tint)
        } else if case .captioned(let caption) = style {
            VStack(spacing: Spacing.xxs) {
                AppIconView(command.icon, size: 26)
                Text(caption)
                    .font(.appCaption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, Spacing.xxs)
        } else {
            AppIconView(command.icon, size: 26)
                .foregroundStyle(command == .powerOff || command == .powerToggle ? Color.appAccent : tint)
        }
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        switch style {
        case .prominent:
            shape.fill(pressed ? Color.appAccent.opacity(0.8) : Color.appAccent)
        case .bare:
            shape.fill(pressed ? Color.appSurfaceRaised : Color.clear)
        case .standard, .captioned:
            ZStack {
                shape.fill(pressed ? Color.appAccentTint : Color.appSurface)
                shape.stroke(pressed ? Color.appAccent.opacity(0.7) : Color.appBorder.opacity(0.8), lineWidth: 1)
            }
        }
    }
}

/// Main navigation control: four directions plus OK, as in the design ("Buttons" mode).
struct DPadView: View {
    let hold: KeyHoldController
    var isEnabled: Bool
    /// Height available for the pad; keys shrink with it but stay ≥ 44 pt.
    var height: CGFloat = 196

    var body: some View {
        let gap: CGFloat = 6
        let key = max(HitTarget.minimum, (height - 2 * gap) / 3)
        let width = key * 1.45
        VStack(spacing: gap) {
            RemoteKeyButton(command: .up, width: width, height: key, hold: hold, isEnabled: isEnabled)
            HStack(spacing: gap) {
                RemoteKeyButton(command: .left, width: width, height: key, hold: hold, isEnabled: isEnabled)
                RemoteKeyButton(command: .ok, width: width, height: key, style: .prominent, hold: hold, isEnabled: isEnabled)
                RemoteKeyButton(command: .right, width: width, height: key, hold: hold, isEnabled: isEnabled)
            }
            RemoteKeyButton(command: .down, width: width, height: key, hold: hold, isEnabled: isEnabled)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.tr("remote.dpad.accessibility"))
    }
}

/// Swipe surface mapped to arrow keys; tap = OK. The Buttons mode is always one tap away.
struct TouchpadView: View {
    let hold: KeyHoldController
    var isEnabled: Bool
    var height: CGFloat = 196
    @State private var lastStep: CGSize = .zero
    private let stepDistance: CGFloat = 36

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(Color.appBackground.opacity(0.55))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Color.appBorder.opacity(0.6), lineWidth: 1))
            .overlay {
                VStack(spacing: Spacing.m) {
                    Grid(horizontalSpacing: 22, verticalSpacing: 18) {
                        ForEach(0..<3, id: \.self) { _ in
                            GridRow {
                                ForEach(0..<3, id: \.self) { _ in
                                    Circle().fill(Color.appTextSecondary.opacity(0.7)).frame(width: 5, height: 5)
                                }
                            }
                        }
                    }
                    .accessibilityHidden(true)
                    if height >= 120 {
                        Text(verbatim: "\(L10n.tr("v2.remote.swipe")) · \(L10n.tr("v2.remote.tap"))")
                            .font(.appFootnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, Spacing.s)
                    }
                }
            }
            .frame(height: height)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        let dx = value.translation.width - lastStep.width
                        let dy = value.translation.height - lastStep.height
                        if abs(dx) >= stepDistance, abs(dx) > abs(dy) {
                            tap(dx > 0 ? .right : .left)
                            lastStep.width = value.translation.width
                            lastStep.height = value.translation.height
                        } else if abs(dy) >= stepDistance {
                            tap(dy > 0 ? .down : .up)
                            lastStep.width = value.translation.width
                            lastStep.height = value.translation.height
                        }
                    }
                    .onEnded { value in
                        guard isEnabled else { return }
                        if abs(value.translation.width) < 8, abs(value.translation.height) < 8 { tap(.ok) }
                        lastStep = .zero
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(L10n.tr("remote.touchpad.accessibility"))
            .accessibilityHint(L10n.tr("remote.touchpad.accessibilityHint"))
            .accessibilityAdjustableAction { direction in
                tap(direction == .increment ? .up : .down)
            }
            .accessibilityAction { tap(.ok) }
    }

    private func tap(_ command: RemoteCommand) {
        Haptics.selection()
        hold.touchDown(command)
        hold.touchUp(command)
    }
}

/// "−  🔊 Volume  +" bar; the same shape serves the channel rocker in More controls.
struct RockerBar: View {
    let title: String
    var icon: String?
    let down: RemoteCommand
    let up: RemoteCommand
    let hold: KeyHoldController
    var isEnabled: Bool
    var height: CGFloat = 52

    var body: some View {
        HStack(spacing: 0) {
            RemoteKeyButton(command: down, width: 64, height: height - 8, style: .bare, hold: hold, isEnabled: isEnabled)
            divider
            HStack(spacing: Spacing.xs) {
                if let icon { AppIconView(icon, size: 22).foregroundStyle(Color.appTextPrimary) }
                Text(title)
                    .font(.appFootnote.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            divider
            RemoteKeyButton(command: up, width: 64, height: height - 8, style: .bare, hold: hold, isEnabled: isEnabled)
        }
        .padding(.horizontal, Spacing.xxs)
        .frame(height: height)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).stroke(Color.appBorder.opacity(0.8), lineWidth: 1))
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
    }

    private var divider: some View {
        Rectangle().fill(Color.appBorder).frame(width: 1, height: height * 0.45)
    }
}
