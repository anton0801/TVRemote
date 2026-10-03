import SwiftUI

/// Screens pushed from the remote.
enum RemoteRoute: Hashable {
    case keyboard
    case apps
}

/// Main remote (design 04/05): TV card with the free-check line, power, cast shortcuts,
/// quick launch, Touchpad/Buttons, Back/Home/Keyboard/More and volume.
struct RemoteScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var hold: KeyHoldController?
    @State private var path: [RemoteRoute] = []
    @State private var showMore = false
    @State private var wake = WakeAction()
    /// The pad takes the height that is left so the whole remote fits on screen without
    /// scrolling (measured, then corrected once: content height is linear in the pad height).
    @State private var viewportHeight: CGFloat = 700
    @State private var contentHeight: CGFloat = 0
    @State private var padHeight: CGFloat = 180

    private var connection: ConnectionManager { model.connection }
    private var device: TVDevice? { model.devices.selectedDevice }
    private var isConnected: Bool { connection.state.isConnected }

    private func supports(_ command: RemoteCommand) -> Bool {
        connection.session?.supportedCommands.contains(command) ?? false
    }

    private func fitPad() {
        guard contentHeight > 0 else { return }
        let target = dynamicTypeSize.isAccessibilitySize ? 196 : min(230, max(144, padHeight + viewportHeight - contentHeight))
        if abs(target - padHeight) > 1 { padHeight = target }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 10) {
                    ScreenHeader(title: L10n.tr("remote.title")) { proButton }
                    tvRow
                    statusArea
                    if let hold {
                        controls(hold)
                    }
                }
                .padding(.horizontal, Spacing.screen)
                .padding(.top, Spacing.xxs)
                .padding(.bottom, Spacing.s)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0; fitPad() }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0; fitPad() }
            .appScreenBackground()
            .statusBarBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: RemoteRoute.self) { route in
                switch route {
                case .keyboard: KeyboardView()
                case .apps: TVAppsView()
                }
            }
            .sheet(isPresented: $showMore) {
                if let hold {
                    MoreControlsSheet(hold: hold, supports: supports, wake: wake)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
        .onAppear {
            if hold == nil {
                hold = KeyHoldController(
                    send: { [model] command, action in model.sendCommand(command, action: action) },
                    supportsPressRelease: { [model] command in model.connection.supportsPressRelease(command) },
                    currentSessionID: { [model] in model.connection.sessionID }
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { hold?.cancelAll() }
        }
        // Report the local sheet so root-level presentations (paywall, help, pairing) can close it.
        .onChange(of: showMore) { _, open in model.localSheetOpen = open }
        .onChange(of: model.closeLocalSheetsSignal) { _, _ in
            hold?.cancelAll()
            showMore = false
        }
        .onDisappear { wake.cancel() }
        .onChange(of: connection.sessionID) { _, _ in hold?.cancelAll() }
        .onChange(of: connection.state) { _, state in
            if !state.isConnected {
                hold?.cancelAll()
                // A pushed keyboard or app list is meaningless without the TV.
                if case .idle = state { path.removeAll() }
            }
            if state.isConnected { wake.reset() }
        }
    }

    // MARK: Header

    @ViewBuilder
    private var proButton: some View {
        Button {
            if model.access.hasPro {
                model.present(.remotePro)
            } else {
                model.paywall.present(.remote, feature: nil, deviceID: model.devices.selectedDeviceID)
            }
        } label: {
            ProBadge()
                .frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum, alignment: .trailing)
        }
        .accessibilityLabel(model.access.hasPro ? L10n.tr("pro.badge.accessibility") : L10n.tr("v2.pro.explore"))
        .accessibilityIdentifier("remote.pro")
    }

    // MARK: TV row

    @ViewBuilder
    private var tvRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .trailing, spacing: Spacing.s) {
                TVStatusCard { freeCheckLine }
                powerButton
            }
        } else {
            HStack(alignment: .center, spacing: Spacing.s) {
                TVStatusCard { freeCheckLine }
                powerButton
            }
        }
    }

    /// Compact status of the free check (design: under the TV). Hidden for Remote Pro.
    @ViewBuilder
    private var freeCheckLine: some View {
        if case .connected(let id) = connection.state {
            switch model.access.decision(.remote, device: id) {
            case .full:
                if model.entitlements.state == .verifying {
                    Text(L10n.tr("access.verifying"))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                }
            case .diagnostic(let remaining):
                Text(verbatim: "\(L10n.tr("v2.remote.freeCheck")) · \(FreeCheckText.remaining(remaining))")
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("remote.freeCheck")
            case .requiresPro:
                Text(L10n.tr("v2.remote.checkDone"))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var powerButton: some View {
        let powerCommand: RemoteCommand? = supports(.powerOff) ? .powerOff : (supports(.powerToggle) ? .powerToggle : nil)
        if isConnected, let powerCommand, let hold {
            RemoteKeyButton(command: powerCommand, width: 56, height: 56, hold: hold)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.appBorder.opacity(0.8), lineWidth: 1))
        } else if !isConnected, let device, device.macAddress != nil {
            // TV is off or away: the same button wakes it over the network when possible.
            Button {
                wake.send(to: device, connection: connection)
            } label: {
                AppIconView("icon-power", size: 26)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.appSurface))
                    .overlay(Circle().stroke(Color.appBorder.opacity(0.8), lineWidth: 1))
            }
            .disabled(wake.state == .sending)
            .accessibilityLabel(L10n.tr("remote.wake"))
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusArea: some View {
        switch connection.state {
        case .idle:
            if let device {
                VStack(spacing: Spacing.s) {
                    InlineNoticeView(kind: .info, text: L10n.tr("remote.status.disconnected", device.displayName),
                                     actionTitle: L10n.tr("remote.reconnect")) { connection.connect(to: device) }
                    wakeStatus(device)
                }
            } else {
                StateMessageView(art: ArtAsset.connection.rawValue, title: L10n.tr("remote.noTV.title"), message: L10n.tr("remote.noTV.message"),
                                 primaryTitle: L10n.tr("remote.noTV.action"), primaryAction: { model.sheet = .discovery })
            }
        case .connecting, .pairing:
            InlineNoticeView(kind: .info, text: L10n.tr("remote.status.connecting"))
        case .reconnecting(_, let attempt):
            InlineNoticeView(kind: .warning, text: L10n.tr("remote.status.reconnecting", attempt))
        case .failed(let id, let error):
            VStack(spacing: Spacing.s) {
                ErrorCard(error: error, feature: "remote") { action in
                    switch action {
                    case .retry:
                        if let device = model.devices.device(id) { connection.connect(to: device) }
                    case .pairAgain:
                        if let device = model.devices.device(id) { connection.pairAgain(device) }
                    case .searchAgain:
                        model.sheet = .discovery
                    default:
                        break
                    }
                }
                if let device = model.devices.device(id) { wakeStatus(device) }
            }
        case .connected(let id):
            if case .requiresPro = model.access.decision(.remote, device: id) {
                InlineNoticeView(kind: .info, text: L10n.tr("diagnostic.remote.exhausted"),
                                 actionTitle: L10n.tr("v2.pro.explore"), compact: true) {
                    model.paywall.present(.remote, feature: .remote, deviceID: id)
                }
                .accessibilityIdentifier("remote.unlock")
            }
            if let error = connection.lastCommandError {
                InlineNoticeView(kind: .warning, text: error.localizedMessage, actionTitle: L10n.tr("common.dismiss")) {
                    connection.clearCommandError()
                }
            }
        }
    }

    @ViewBuilder
    private func wakeStatus(_ device: TVDevice) -> some View {
        Group {
            switch wake.state {
            case .sent: Text(L10n.tr("remote.wake.sent"))
            case .notPermitted: Text(L10n.tr("remote.wake.notPermitted"))
            case .sending, .idle:
                if device.macAddress == nil { Text(L10n.tr("remote.wake.unavailable")) }
            }
        }
        .font(.appFootnote)
        .foregroundStyle(Color.appTextSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Controls

    @ViewBuilder
    private func controls(_ hold: KeyHoldController) -> some View {
        let enabled = isConnected
        let ax = dynamicTypeSize.isAccessibilitySize
        VStack(spacing: 10) {
            let shortcuts = ax ? AnyLayout(VStackLayout(spacing: Spacing.xs)) : AnyLayout(HStackLayout(spacing: Spacing.xs))
            shortcuts {
                CastShortcut(icon: "icon-photo", title: L10n.tr("v2.cast.photos")) { model.openCast(.photos) }
                CastShortcut(icon: "icon-video", title: L10n.tr("v2.cast.videos")) { model.openCast(.videos) }
            }

            FavoriteAppsStrip(showAll: {
                guard model.remoteAllowed() else { return }
                path.append(.apps)
            })

            VStack(spacing: Spacing.xxs) {
                ChoiceSegment(options: [
                    (RemoteInputStyle.touchpad, L10n.tr("v2.remote.touchpad"), "icon-touchpad"),
                    (RemoteInputStyle.dpad, L10n.tr("v2.remote.buttons"), "icon-buttons"),
                ], selection: Binding(get: { model.settings.remoteInputStyle }, set: { model.settings.remoteInputStyle = $0 }))
                .frame(maxWidth: 300)
                .accessibilityIdentifier("remote.inputStyle")
                if model.settings.remoteInputStyle == .touchpad {
                    TouchpadView(hold: hold, isEnabled: enabled, height: padHeight)
                } else {
                    DPadView(hold: hold, isEnabled: enabled, height: padHeight)
                        .padding(.vertical, Spacing.xxs)
                }
            }
            .padding(Spacing.xs)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Color.appBorder.opacity(0.7), lineWidth: 1))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.xs), count: ax ? 2 : 4), spacing: Spacing.xs) {
                RemoteKeyButton(command: .back, height: ax ? 96 : 60, style: .captioned(L10n.tr("v2.action.back")), hold: hold, isEnabled: enabled && supports(.back))
                RemoteKeyButton(command: .home, height: ax ? 96 : 60, style: .captioned(L10n.tr("v2.remote.home")), hold: hold, isEnabled: enabled && supports(.home))
                CaptionedButton(icon: "icon-keyboard", title: L10n.tr("v2.remote.keyboard"), isEnabled: enabled && connection.session?.textInputMode != nil) {
                    guard model.remoteAllowed() else { return }
                    path.append(.keyboard)
                }
                .accessibilityIdentifier("remote.keyboard")
                CaptionedButton(icon: "icon-more", title: L10n.tr("v2.remote.more"), isEnabled: enabled) {
                    showMore = true
                }
                .accessibilityIdentifier("remote.more")
            }

            HStack(spacing: Spacing.xs) {
                RockerBar(title: L10n.tr("v2.remote.volume"), icon: "icon-volume", down: .volumeDown, up: .volumeUp,
                          hold: hold, isEnabled: enabled && supports(.volumeUp), height: 50)
                RemoteKeyButton(command: .mute, width: 64, height: 50, hold: hold, isEnabled: enabled && supports(.mute))
            }
        }
    }
}

/// Free-check time in calm words: whole minutes, no ticking seconds.
enum FreeCheckText {
    static func remaining(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return L10n.tr("freeCheck.lessThanMinute") }
        return L10n.tr("freeCheck.minutesLeft", Int((seconds / 60).rounded(.up)))
    }
}

/// Wake-on-LAN from the remote: the power button and More controls share it.
@MainActor
@Observable
final class WakeAction {
    enum State: Equatable { case idle, sending, sent, notPermitted }

    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    func send(to device: TVDevice, connection: ConnectionManager) {
        guard let mac = device.macAddress else { return }
        state = .sending
        task?.cancel()
        task = Task { [weak self, connection] in
            let outcome = await WakeOnLAN.send(mac: mac, lastKnownHost: device.host)
            self?.state = outcome == .sent ? .sent : .notPermitted
            guard outcome == .sent else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            // Only if nothing happened meanwhile (no manual connect, no other TV).
            switch connection.state {
            case .idle, .failed(device.id, _): connection.connect(to: device)
            default: break
            }
        }
    }

    func reset() {
        state = .idle
    }

    func cancel() {
        task?.cancel()
    }
}

/// "Cast photos ›" / "Cast videos ›" on the remote.
private struct CastShortcut: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                AppIconView(icon, size: 26).foregroundStyle(Color.appAccent)
                Text(title)
                    .font(.appSecondary.weight(.medium))
                    .foregroundStyle(Color.appTextPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                AppIconView("icon-chevron-right", size: 14).foregroundStyle(Color.appTextSecondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).stroke(Color.appBorder.opacity(0.8), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Non-repeating key with icon and caption (Keyboard, More).
struct CaptionedButton: View {
    let icon: String
    let title: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.xxs) {
                AppIconView(icon, size: 26)
                Text(title)
                    .font(.appCaption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Color.appTextPrimary)
            .padding(.horizontal, Spacing.xxs)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).stroke(Color.appBorder.opacity(0.8), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

/// More controls (design 44): channels, media keys, menu/input/wake and numbers. Keys the TV
/// doesn't support are left out instead of showing dead buttons.
private struct MoreControlsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let hold: KeyHoldController
    let supports: (RemoteCommand) -> Bool
    let wake: WakeAction

    private var mediaKeys: [(RemoteCommand, String)] {
        [(.rewind, L10n.tr("key.rewind")), (supports(.playPause) ? .playPause : .play, L10n.tr("key.playPause")),
         (.fastForward, L10n.tr("key.fastForward")), (.menu, L10n.tr("v2.remote.menu")), (.input, L10n.tr("v2.remote.input")),
         (.stop, L10n.tr("key.stop")), (.previous, L10n.tr("key.previous")), (.next, L10n.tr("key.next")),
         (.info, L10n.tr("key.info")), (.guide, L10n.tr("key.guide")), (.settings, L10n.tr("key.settings"))]
            .filter { supports($0.0) }
    }

    private let grid = Array(repeating: GridItem(.flexible(), spacing: Spacing.xs), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.tr("v2.remote.moreTitle"))
                        .font(.appScreenTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button { dismiss() } label: {
                        AppIconView("icon-close", size: 18)
                            .foregroundStyle(Color.appTextPrimary)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.appSurfaceRaised))
                    }
                    .accessibilityLabel(L10n.tr("v2.action.close"))
                }
                TVStatusCard(showsMenu: false, compact: true)

                if supports(.channelUp) {
                    SectionHeader(title: L10n.tr("v2.remote.channels"))
                    RockerBar(title: L10n.tr("remote.channel"), down: .channelDown, up: .channelUp, hold: hold, isEnabled: true)
                }

                if !mediaKeys.isEmpty || model.devices.selectedDevice?.macAddress != nil {
                    LazyVGrid(columns: grid, spacing: Spacing.xs) {
                        ForEach(mediaKeys, id: \.0) { command, title in
                            RemoteKeyButton(command: command, height: 72, style: .captioned(title), hold: hold)
                        }
                        if let device = model.devices.selectedDevice, device.macAddress != nil {
                            CaptionedButton(icon: "icon-wake", title: L10n.tr("v2.remote.wake")) {
                                wake.send(to: device, connection: model.connection)
                            }
                            .frame(minHeight: 72)
                        }
                    }
                }

                if supports(.digit1) {
                    SectionHeader(title: L10n.tr("v2.remote.numbers"))
                    LazyVGrid(columns: grid, spacing: Spacing.xs) {
                        ForEach(RemoteCommand.digits.dropLast(), id: \.self) { digit in
                            RemoteKeyButton(command: digit, height: 52, hold: hold)
                        }
                        Color.clear.frame(height: 52).accessibilityHidden(true)
                        RemoteKeyButton(command: .digit0, height: 52, hold: hold, isEnabled: supports(.digit0))
                        Color.clear.frame(height: 52).accessibilityHidden(true)
                    }
                }

                if wake.state == .sent {
                    InfoNote(text: L10n.tr("remote.wake.sent"))
                }
                Text(L10n.tr("remote.more.footer"))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
            .padding(Spacing.screen)
        }
        .background(Color.appBackground.ignoresSafeArea())
    }
}

/// Quick launch row on the remote: four equal logo tiles with captions, "All ›" opens the list.
struct FavoriteAppsStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let showAll: () -> Void

    var body: some View {
        let apps = model.apps
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: L10n.tr("v2.remote.quickLaunch"))
                Button(action: showAll) {
                    HStack(spacing: 2) {
                        Text(L10n.tr("v2.remote.all"))
                        AppIconView("icon-chevron-right", size: 14, relativeTo: .footnote)
                    }
                }
                .accessibilityIdentifier("remote.apps.all")
                .font(.appSecondary.weight(.semibold))
                .foregroundStyle(Color.appAccent)
                .frame(minWidth: HitTarget.minimum, minHeight: 30, alignment: .trailing)
                .contentShape(Rectangle().inset(by: -8))
                .disabled(!model.connection.state.isConnected)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.xs, alignment: .top),
                                     count: dynamicTypeSize.isAccessibilitySize ? 2 : 4), spacing: Spacing.xs) {
                ForEach(apps.favorites.prefix(4)) { item in
                    AppTile(item: item, layout: .strip)
                }
            }
            .disabled(!model.connection.state.isConnected)
            .opacity(model.connection.state.isConnected ? 1 : 0.4)
            if model.connection.state.isConnected {
                AppLaunchStatusView()
            }
        }
    }
}
