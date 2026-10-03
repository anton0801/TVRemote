import SwiftUI

struct DiscoveryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let isOnboarding: Bool
    var onConnected: (() -> Void)?
    /// During onboarding the search (and the iOS Local Network prompt) waits for the user.
    @State private var searchRequested = false
    /// The TV the user picked here. Only *its* connection advances or closes this screen — not a
    /// background reconnect of another TV.
    @State private var requestedDeviceID: TVDeviceID?
    @State private var pendingSwitch: PendingTVSwitch?

    private var isBusyConnecting: Bool {
        switch connection.state {
        case .connecting, .pairing: true
        default: false
        }
    }

    private var showsPrimer: Bool { isOnboarding && !searchRequested }

    private var discovery: DiscoveryService { model.discovery }
    private var connection: ConnectionManager { model.connection }

    private var newResults: [DiscoveredTV] {
        discovery.results.filter { tv in tv.platform != .unknown && !model.devices.devices.contains { $0.id == tv.id } }
    }

    var body: some View {
        if showsPrimer {
            primer
        } else {
            results
        }
    }

    /// Design 06: what's needed before the iOS Local Network prompt appears.
    private var primer: some View {
        ScrollView {
            VStack(spacing: Spacing.m) {
                PageHeader(title: L10n.tr("v2.connection.title"))
                Image(ArtAsset.connection.rawValue)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 300, maxHeight: 190)
                    .accessibilityHidden(true)
                VStack(spacing: Spacing.xs) {
                    Text(L10n.tr("v2.connection.sameWifi"))
                        .font(.appScreenTitle)
                        .foregroundStyle(Color.appTextPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(L10n.tr("v2.connection.sameWifi.body"))
                        .font(.appBody)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: Spacing.xs) {
                    PrimerRow(icon: "icon-power", title: L10n.tr("v2.connection.turnOn"), detail: L10n.tr("explain.tvOn"))
                    PrimerRow(icon: "icon-wifi", title: L10n.tr("v2.connection.allowNetwork"), detail: L10n.tr("explain.permission"))
                }
                Text(L10n.tr("v2.connection.networkPurpose"))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.m)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Spacing.xs) {
                Button {
                    searchRequested = true
                    startSearch()
                } label: {
                    Label { Text(L10n.tr("v2.connection.find")) } icon: { ButtonIcon("icon-search") }
                }
                .buttonStyle(.primary)
                .accessibilityIdentifier("discovery.start")
                Button {
                    model.sheet = .help("tvNotFound")
                } label: {
                    Label { Text(L10n.tr("v2.connection.help")) } icon: { ButtonIcon("icon-help") }
                }
                .buttonStyle(.secondary)
                Button(L10n.tr("discovery.skip")) { skipOnboarding() }
                    .buttonStyle(.textAction)
                    .accessibilityIdentifier("discovery.skip")
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.vertical, Spacing.s)
            .background(Color.appBackground.ignoresSafeArea(edges: .bottom))
        }
        .appScreenBackground()
        .pageNavigation(L10n.tr("v2.connection.title"))
    }

    private func skipOnboarding() {
        discovery.stop()
        model.analytics.log(.onboardingCompleted(task: "remote"))
        model.settings.onboardingCompleted = true
    }

    /// Design 07 (list), 28 (nothing found) and 29 (Local Network blocked).
    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                PageHeader(title: L10n.tr("v2.discovery.title"))
                Text(L10n.tr("v2.discovery.found"))
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                    .padding(.bottom, Spacing.xxs)

                if case .failed(let error) = discovery.phase {
                    if error == .localNetworkDenied {
                        NetworkBlockedView()
                    } else {
                        ErrorCard(error: error, feature: "discovery") { action in
                            if action == .searchAgain || action == .retry { startSearch() }
                        }
                    }
                }
                if isOnboarding, let device = connection.connectedDevice {
                    // Came back to this step while already connected: no need to reconnect.
                    Button(L10n.tr("discovery.continueWith", device.displayName)) { onConnected?() }
                        .buttonStyle(.primary)
                }
                if case .failed(let deviceID, let error) = connection.state {
                    ErrorCard(error: error, feature: "pairing") { action in
                        if let device = model.devices.device(deviceID), action == .retry || action == .pairAgain {
                            requestedDeviceID = device.id
                            if action == .pairAgain { connection.pairAgain(device) } else { connection.connect(to: device) }
                        } else if action == .searchAgain {
                            startSearch()
                        }
                    }
                }

                if discovery.isSearching {
                    HStack(spacing: Spacing.s) {
                        ProgressView().tint(.appAccent)
                        Text(L10n.tr("v2.discovery.searching"))
                            .font(.appBody)
                            .foregroundStyle(Color.appTextPrimary)
                        Spacer(minLength: 0)
                    }
                    .surfaceCard()
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(L10n.tr("discovery.searching.detail"))
                }

                ForEach(model.devices.devices) { device in
                    let seen = discovery.results.first { $0.id == device.id }
                    DeviceRow(
                        name: device.displayName,
                        detail: [device.platform.shortName, device.distinguishingDetail].compactMap { $0 }.joined(separator: " · "),
                        status: rowStatus(for: device.id, seenNow: seen != nil)
                    ) {
                        pick(device.id) {
                            if let seen { model.connection.connect(to: seen) } else { model.connection.connect(to: device) }
                        }
                    }
                    .disabled(isBusyConnecting)
                }
                ForEach(newResults) { tv in
                    DeviceRow(
                        name: tv.name,
                        detail: [tv.platform.shortName, tv.modelName].compactMap { $0 }.joined(separator: " · "),
                        status: rowStatus(for: tv.id, seenNow: true)
                    ) {
                        pick(tv.id) { model.connection.connect(to: tv) }
                    }
                    .disabled(isBusyConnecting)
                }

                if discovery.phase == .finished, newResults.isEmpty, model.devices.devices.isEmpty {
                    NoTVFoundView(onSearch: startSearch)
                } else {
                    HStack(alignment: .top, spacing: Spacing.s) {
                        AppIconView("icon-info", size: 22).foregroundStyle(Color.appTextPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("v2.discovery.before")).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                            Text(L10n.tr("v2.discovery.accept")).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .surfaceCard()
                    .accessibilityElement(children: .combine)
                }
                if discovery.multicastUnavailable {
                    InfoNote(text: L10n.tr("discovery.multicastNote"))
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.m)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Button {
                        startSearch()
                    } label: {
                        Label { Text(L10n.tr("v2.discovery.again")) } icon: { ButtonIcon("icon-refresh") }
                    }
                    .buttonStyle(.secondary)
                    .disabled(discovery.isSearching)
                    Button {
                        model.sheet = .help("tvNotFound")
                    } label: {
                        Label { Text(L10n.tr("v2.discovery.notListed")) } icon: { ButtonIcon("icon-help") }
                    }
                    .buttonStyle(.secondary)
                }
                if isOnboarding {
                    Button(L10n.tr("discovery.skip")) { skipOnboarding() }
                        .buttonStyle(.textAction)
                        .accessibilityIdentifier("discovery.skip")
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.vertical, Spacing.s)
            .background(Color.appBackground.ignoresSafeArea(edges: .bottom))
        }
        .appScreenBackground()
        .pageNavigation(L10n.tr("v2.discovery.title"))
        .toolbar {
            if !isOnboarding {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.close")) { dismiss() }
                }
            }
        }
        .onAppear { if discovery.phase == .idle || !discovery.isSearching { startSearch() } }
        .onDisappear { discovery.stop() }
        .onChange(of: connection.state) { _, state in
            guard case .connected(let id) = state, id == requestedDeviceID else { return }
            requestedDeviceID = nil
            discovery.stop()
            if let onConnected { onConnected() } else { dismiss() }
        }
        .modifier(SwitchTVConfirmation(pending: $pendingSwitch))
    }

    /// Connects to the chosen TV (no-op if it's the one already connected; confirmation if
    /// mirroring or casting would stop).
    private func pick(_ id: TVDeviceID, connect: @escaping @MainActor () -> Void) {
        switch model.requestConnection(to: id, connect: connect) {
        case .alreadyConnected:
            if connection.state.isConnected { if let onConnected { onConnected() } else { dismiss() } }
        case .needsConfirmation:
            requestedDeviceID = id
            pendingSwitch = PendingTVSwitch(connect: connect)
        case .started:
            requestedDeviceID = id
        }
    }

    private func startSearch() {
        discovery.start(knownDevices: model.devices.devices)
    }

    private func rowStatus(for id: TVDeviceID, seenNow: Bool) -> DeviceRow.Status {
        switch connection.state {
        case .connecting(let current) where current == id, .pairing(let current) where current == id:
            return .connecting
        case .reconnecting(let current, _) where current == id:
            return .connecting
        case .connected(let current) where current == id:
            return .connected
        default:
            return seenNow ? .available : .notSeen
        }
    }
}

/// TV card in the list (design 07): icon, name, brand line and a Connect button or status.
struct DeviceRow: View {
    enum Status { case available, notSeen, connecting, connected }

    let name: String
    let detail: String
    let status: Status
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                AppIconView("icon-tv", size: 30)
                    .foregroundStyle(Color.appTextPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.appHeadline)
                        .foregroundStyle(Color.appTextPrimary)
                    Text(detail)
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                }
                Spacer(minLength: Spacing.xs)
                switch status {
                case .connecting:
                    ProgressView().tint(.appAccent)
                case .connected:
                    StatusBadge(kind: .ready, text: L10n.tr("v2.status.connected"))
                case .notSeen:
                    StatusBadge(kind: .neutral, text: L10n.tr("device.status.notSeen"))
                case .available:
                    Text(L10n.tr("v2.action.connect"))
                        .font(.appSecondary.weight(.semibold))
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, Spacing.s)
                        .frame(minHeight: 36)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.appAccent, lineWidth: 1.2))
                }
            }
            .surfaceCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.tr("device.connect.hint"))
    }
}

/// Icon tile + title + detail, used on the "Connect your TV" explanation.
private struct PrimerRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            IconTile(name: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                Text(detail).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .surfaceCard()
        .accessibilityElement(children: .combine)
    }
}

/// Design 28: nothing found yet, with the fixes that usually help.
struct NoTVFoundView: View {
    @Environment(AppModel.self) private var model
    let onSearch: () -> Void

    var body: some View {
        VStack(spacing: Spacing.s) {
            Image(ArtAsset.noTV.rawValue)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: 260, maxHeight: 170)
                .accessibilityHidden(true)
            Text(L10n.tr("v2.error.noTV"))
                .font(.appScreenTitle)
                .foregroundStyle(Color.appTextPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(L10n.tr("discovery.empty.message"))
                .font(.appBody)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ActionRow(icon: "icon-wifi", title: L10n.tr("discovery.fix.localNetwork"), detail: L10n.tr("discovery.fix.localNetwork.detail")) {
                model.bonus.expectReturn()
                SystemLinks.openAppSettings()
            }
            ActionRow(icon: "icon-wifi-off", title: L10n.tr("v2.error.guestWifi"), detail: L10n.tr("discovery.fix.guest.detail")) {
                model.sheet = .help("tvNotFound")
            }
            ActionRow(icon: "icon-refresh", title: L10n.tr("discovery.fix.again"), detail: L10n.tr("discovery.fix.again.detail"), action: onSearch)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Design 29: Local Network access is off — the two steps to turn it on.
struct NetworkBlockedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: Spacing.s) {
            Image(ArtAsset.permission.rawValue)
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxWidth: 260, maxHeight: 170)
                .accessibilityHidden(true)
            Text(L10n.tr("v2.error.networkOff"))
                .font(.appBannerTitle)
                .foregroundStyle(Color.appTextPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Spacing.s) {
                NumberedStep(number: 1, icon: "icon-settings", title: L10n.tr("v2.action.openSettings"))
                NumberedStep(number: 2, icon: "icon-globe", title: L10n.tr("permission.enableLocalNetwork"))
            }
            .surfaceCard()
            Button {
                model.bonus.expectReturn()
                SystemLinks.openAppSettings()
            } label: {
                Label { Text(L10n.tr("v2.action.openSettings")) } icon: { ButtonIcon("icon-settings") }
            }
            .buttonStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Tappable row with a leading icon tile and a chevron (only for rows that do something).
struct ActionRow: View {
    let icon: String
    let title: String
    var detail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                AppIconView(icon, size: 26).foregroundStyle(Color.appAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                    if let detail {
                        Text(detail).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Spacing.xs)
                AppIconView("icon-chevron-right", size: 16).foregroundStyle(Color.appTextSecondary)
            }
            .multilineTextAlignment(.leading)
            .surfaceCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
