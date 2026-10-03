import SwiftUI

extension TVPlatform {
    /// Short brand line under a TV name ("Samsung TV · Connected"). Product names, not translated.
    var shortName: String {
        switch self {
        case .samsungTizen: "Samsung TV"
        case .lgWebOS: "LG TV"
        case .androidTV: "Android TV"
        case .unknown: "TV"
        }
    }
}

/// Connection status of the selected TV in the words the design uses.
struct TVConnectionStatus {
    enum Tone { case ready, pending, neutral, error }

    let text: String
    let tone: Tone

    @MainActor
    static func of(_ device: TVDevice, in state: ConnectionManager.State) -> TVConnectionStatus {
        guard state.deviceID == device.id else { return TVConnectionStatus(text: L10n.tr("v2.status.offline"), tone: .neutral) }
        switch state {
        case .connected: return TVConnectionStatus(text: L10n.tr("v2.status.connected"), tone: .ready)
        case .connecting: return TVConnectionStatus(text: L10n.tr("tv.status.connecting"), tone: .pending)
        case .pairing: return TVConnectionStatus(text: L10n.tr("tv.status.awaitingApproval"), tone: .pending)
        case .reconnecting: return TVConnectionStatus(text: L10n.tr("tv.status.reconnecting"), tone: .pending)
        case .failed: return TVConnectionStatus(text: L10n.tr("tv.status.notConnected"), tone: .error)
        case .idle: return TVConnectionStatus(text: L10n.tr("v2.status.offline"), tone: .neutral)
        }
    }

    var dotColor: Color {
        switch tone {
        case .ready: .appSuccess
        case .pending: .appAccent
        case .neutral: .appTextSecondary
        case .error: .appDanger
        }
    }
}

/// The selected TV: name, status dot, "Samsung TV · Connected", optional footer line and a menu
/// to switch TVs. Same component on Remote, Cast, mirroring, Now playing and More controls.
struct TVStatusCard<Footer: View>: View {
    @Environment(AppModel.self) private var model
    var showsMenu = true
    var compact = false
    @ViewBuilder var footer: () -> Footer
    @State private var pendingSwitch: PendingTVSwitch?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if showsMenu {
                Menu { menuContent } label: { card(chevron: true) }
                    .buttonStyle(.plain)
                    .accessibilityHint(L10n.tr("tv.card.hint"))
                    .accessibilityIdentifier("remote.tvCard")
            } else {
                card(chevron: false)
            }
        }
        .modifier(SwitchTVConfirmation(pending: $pendingSwitch))
    }

    private func card(chevron: Bool) -> some View {
        let device = model.devices.selectedDevice
        let status = device.map { TVConnectionStatus.of($0, in: model.connection.state) }
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                AppIconView("icon-tv", size: compact ? 26 : 30)
                    .foregroundStyle(Color.appTextPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.xs) {
                        Text(device?.displayName ?? L10n.tr("header.noTV"))
                            .font(.appHeadline)
                            .foregroundStyle(Color.appTextPrimary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        if let status {
                            Circle().fill(status.dotColor).frame(width: 8, height: 8).accessibilityHidden(true)
                        }
                    }
                    if let device, let status {
                        Text(verbatim: "\(device.platform.shortName) · \(status.text)")
                            .font(.appFootnote)
                            .foregroundStyle(Color.appTextSecondary)
                            .lineLimit(2)
                    } else {
                        Text(L10n.tr("tv.card.addFirst"))
                            .font(.appFootnote)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
                Spacer(minLength: Spacing.xs)
                if chevron {
                    AppIconView("icon-chevron-down", size: 20)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
            footer()
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, compact ? Spacing.s : Spacing.s + 2)
        .frame(maxWidth: .infinity, minHeight: compact ? 56 : 64, alignment: .leading)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Color.appBorder.opacity(0.7), lineWidth: 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(device.map { L10n.tr("header.accessibility", $0.displayName) } ?? L10n.tr("header.noTV"))
        .accessibilityValue(status?.text ?? "")
    }

    @ViewBuilder
    private var menuContent: some View {
        ForEach(model.devices.devices) { device in
            Button {
                select(device)
            } label: {
                let detail = [device.platform.shortName, device.distinguishingDetail].compactMap { $0 }.joined(separator: " · ")
                if device.id == model.devices.selectedDeviceID {
                    Label {
                        Text(device.displayName)
                        Text(detail)
                    } icon: {
                        Image(systemName: "checkmark")
                    }
                } else {
                    Text(device.displayName)
                    Text(detail)
                }
            }
        }
        Divider()
        if model.connection.state.isConnected {
            Button {
                model.sheet = .compatibility
            } label: {
                Label(L10n.tr("remote.compatibility"), systemImage: "checklist")
            }
            .accessibilityIdentifier("tvCard.compatibility")
        }
        Button {
            model.sheet = .discovery
        } label: {
            Label(L10n.tr("header.addTV"), systemImage: "plus")
        }
    }

    private func select(_ device: TVDevice) {
        let connect: @MainActor () -> Void = { [model] in model.connection.connect(to: device) }
        if model.requestConnection(to: device.id, connect: connect) == .needsConfirmation {
            pendingSwitch = PendingTVSwitch(connect: connect)
        }
    }
}

extension TVStatusCard where Footer == EmptyView {
    init(showsMenu: Bool = true, compact: Bool = false) {
        self.init(showsMenu: showsMenu, compact: compact) { EmptyView() }
    }
}
