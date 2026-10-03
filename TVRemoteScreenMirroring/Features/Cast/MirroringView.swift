import ReplayKit
import SwiftUI

/// Screen mirroring: setup (design 17), live session (18), quality (45), receiver needed (35)
/// and connection lost (27). Only the picture is sent; audio stays on the iPhone.
struct MirroringView: View {
    @Environment(AppModel.self) private var model
    @Environment(LocalizationManager.self) private var localization

    private var mirroring: MirroringController { model.mirroring }

    @State private var readinessCheck = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                PageHeader(title: mirroring.isActive ? L10n.tr("v2.cast.mirror") : L10n.tr("v2.mirror.title"))
                switch mirroring.phase {
                case .idle:
                    setup
                case .openingReceiver, .waitingForTV:
                    session(waiting: true)
                case .streaming, .stopping:
                    session(waiting: false)
                case .ended(let reason):
                    ended(reason)
                case .failed(let error):
                    failed(error)
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.l)
        }
        .appScreenBackground()
        .pageNavigation(mirroring.isActive ? L10n.tr("v2.cast.mirror") : L10n.tr("v2.mirror.title"))
        .toolbar(.visible, for: .navigationBar)
        .onAppear { armIfPossible() }
        .onChange(of: model.connection.state) { _, _ in armIfPossible() }
        .onChange(of: model.entitlements.state) { _, _ in armIfPossible() }
        // "Back to setup" / a finished session returns to idle: prepare the next start.
        .onChange(of: mirroring.phase) { _, phase in if phase == .idle { armIfPossible() } }
        .onDisappear { mirroring.disarm() }
    }

    private func armIfPossible() {
        guard mirroring.phase == .idle else { return }
        mirroring.arm(languageCode: localization.effectiveCode)
    }

    // MARK: Setup (17)

    @ViewBuilder
    private var setup: some View {
        let _ = readinessCheck // re-evaluated when the user asks to check again
        let readiness = mirroring.readiness()
        let device = model.connection.connectedDevice
        if readiness == .mirroringReceiverMissing {
            receiverNeeded
        } else {
            MirrorArt()
                .frame(height: 150)
                .frame(maxWidth: .infinity)
            TVStatusCard()
            VStack(spacing: 0) {
                CheckRow(icon: "icon-wifi", title: L10n.tr("v2.mirror.network"),
                         detail: readiness == .noWiFi ? L10n.tr("mirroring.setup.network.none") : L10n.tr("mirroring.setup.network.ok"),
                         ok: readiness != .noWiFi)
                Divider().overlay(Color.appBorder).padding(.leading, 56)
                CheckRow(icon: "icon-tv", title: L10n.tr("v2.mirror.connection"),
                         detail: device?.displayName ?? L10n.tr("header.noTV"), ok: device != nil)
                Divider().overlay(Color.appBorder).padding(.leading, 56)
                CheckRow(icon: "icon-cast", title: L10n.tr("v2.mirror.receiver"),
                         detail: L10n.tr("mirroring.setup.receiver.browser"), ok: device != nil)
            }
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Color.appBorder.opacity(0.7), lineWidth: 1))

            if let readiness {
                ErrorCard(error: readiness, feature: "mirroring") { action in
                    switch action {
                    case .retry:
                        if let device = model.devices.selectedDevice { model.connection.connect(to: device) }
                    case .searchAgain:
                        // No Wi-Fi: check again (e.g. after the user turned Wi-Fi on).
                        readinessCheck += 1
                        armIfPossible()
                    default:
                        break
                    }
                }
            } else {
                InfoNote(text: L10n.tr("v2.mirror.audioLocal") + ". " + L10n.tr("v2.mirror.pictureOnly"), boxed: true)
                InfoNote(text: L10n.tr("v2.mirror.privacy"), boxed: true)
                Text(L10n.tr("mirroring.limits"))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                startArea
            }
        }
    }

    @ViewBuilder
    private var startArea: some View {
        switch mirroring.accessDecision() {
        case .requiresPro?:
            Text(L10n.tr("diagnostic.mirroring.exhausted"))
                .font(.appFootnote)
                .foregroundStyle(Color.appTextSecondary)
            Button(L10n.tr("v2.pro.explore")) { mirroring.requestUnlock() }
                .buttonStyle(.primary)
        case .diagnostic(let remaining)?:
            startButton
            Text(L10n.tr("diagnostic.mirroring.available", Int(remaining)))
                .font(.appFootnote)
                .foregroundStyle(Color.appTextSecondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        default:
            startButton
        }
        NavigationLink {
            HelpArticleScreen(articleID: "mirroringProblem")
        } label: {
            HStack(spacing: Spacing.xs) {
                Text(L10n.tr("v2.mirror.how"))
                AppIconView("icon-chevron-right", size: 14, relativeTo: .body)
            }
        }
        .buttonStyle(.secondary)
        Text(L10n.tr("v2.mirror.systemConfirm"))
            .font(.appFootnote)
            .foregroundStyle(Color.appTextSecondary)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var startButton: some View {
        if mirroring.isArmed {
            BroadcastStartButton(title: L10n.tr("v2.mirror.continue"))
                .frame(height: HitTarget.primaryButton)
                .accessibilityIdentifier("mirroring.start")
        } else {
            ProgressView().tint(.appAccent).frame(maxWidth: .infinity)
        }
    }

    /// Design 35: this TV has no receiver we can open. Other features stay available.
    @ViewBuilder
    private var receiverNeeded: some View {
        TVStatusCard()
        Image(ArtAsset.noTV.rawValue)
            .resizable().aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 180)
            .accessibilityHidden(true)
        Text(L10n.tr("v2.receiver.title"))
            .font(.appScreenTitle)
            .foregroundStyle(Color.appTextPrimary)
            .accessibilityAddTraits(.isHeader)
        Text(L10n.tr("mirroring.unsupportedPlatform"))
            .font(.appBody)
            .foregroundStyle(Color.appTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        NavigationLink {
            HelpArticleScreen(articleID: "mirroringProblem")
        } label: {
            Label { Text(L10n.tr("v2.receiver.guide")) } icon: { ButtonIcon("icon-document") }
        }
        .buttonStyle(.outline)
        Button {
            model.sheet = .discovery
        } label: {
            Label { Text(L10n.tr("v2.error.otherTV")) } icon: { ButtonIcon("icon-tv") }
        }
        .buttonStyle(.secondary)
        InfoNote(text: L10n.tr("v2.receiver.otherFeatures"))
    }

    // MARK: Session (18)

    @ViewBuilder
    private func session(waiting: Bool) -> some View {
        TVStatusCard(showsMenu: false, compact: true)
        VStack(spacing: Spacing.s) {
            ZStack {
                Circle().fill(Color.appAccent.opacity(0.12)).frame(width: 150, height: 150)
                Circle().fill(Color.appAccent.opacity(0.18)).frame(width: 112, height: 112)
                AppIconView("icon-cast", size: 54).foregroundStyle(Color.appAccent)
            }
            .accessibilityHidden(true)
            Text(waiting ? L10n.tr("mirroring.status.waiting") : L10n.tr("v2.mirror.active"))
                .font(.appBannerTitle)
                .foregroundStyle(Color.appTextPrimary)
            if waiting {
                Text(L10n.tr("mirroring.status.waiting.detail"))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(spacing: Spacing.xxs) {
                        Text(Duration.seconds(mirroring.status.confirmedSeconds()).formatted(.time(pattern: .minuteSecond)))
                            .font(.appBannerTitle.monospacedDigit())
                            .foregroundStyle(Color.appAccent)
                            .accessibilityLabel(L10n.tr("mirroring.duration", Duration.seconds(mirroring.status.confirmedSeconds()).formatted(.time(pattern: .minuteSecond))))
                        if let remaining = mirroring.diagnosticRemaining {
                            Text(L10n.tr("diagnostic.mirroring.remaining", Int(remaining)))
                                .font(.appFootnote)
                                .foregroundStyle(Color.appTextSecondary)
                        }
                    }
                }
            }
            NavigationLink {
                MirroringQualityView()
            } label: {
                HStack {
                    Text(L10n.tr("v2.mirror.quality")).font(.appBody).foregroundStyle(Color.appTextPrimary)
                    Spacer()
                    Text(mirroring.quality.title).font(.appBody).foregroundStyle(Color.appTextSecondary)
                    AppIconView("icon-chevron-right", size: 16).foregroundStyle(Color.appTextSecondary)
                }
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: HitTarget.row)
                .background(Color.appSurfaceRaised, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .surfaceCard()

        VStack(spacing: 0) {
            InfoLine(icon: "icon-phone", title: L10n.tr("v2.mirror.audioLocal"), detail: L10n.tr("v2.mirror.pictureOnly"))
            Divider().overlay(Color.appBorder).padding(.leading, 56)
            InfoLine(icon: "icon-shield", title: L10n.tr("mirroring.visibleNote"), detail: nil)
        }
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Color.appBorder.opacity(0.7), lineWidth: 1))

        Button {
            Task { await mirroring.stop() }
        } label: {
            if mirroring.phase == .stopping {
                ProgressView().tint(.white)
            } else {
                Label { Text(L10n.tr("v2.mirror.stop")) } icon: { ButtonIcon("icon-stop") }
            }
        }
        .buttonStyle(.destructive)
        .disabled(mirroring.phase == .stopping)
        .accessibilityHint(L10n.tr("mirroring.stop.hint"))
        .accessibilityIdentifier("mirroring.stop")
        Button {
            model.present(.help("mirroringProblem"))
        } label: {
            Label { Text(L10n.tr("v2.connection.help")) } icon: { ButtonIcon("icon-help") }
        }
        .buttonStyle(.secondary)
    }

    // MARK: Ended / failed

    @ViewBuilder
    private func ended(_ reason: MirroringStatus.StopReason) -> some View {
        StateMessageView(
            art: reason == .diagnosticLimit ? ArtAsset.pending.rawValue : ArtAsset.success.rawValue,
            title: L10n.tr("mirroring.ended.title"),
            message: L10n.tr(reason == .diagnosticLimit ? "mirroring.ended.test" : "mirroring.ended.message"),
            primaryTitle: L10n.tr("mirroring.backToSetup"),
            primaryAction: { mirroring.acknowledgeEnd() }
        )
        .frame(maxWidth: .infinity)
    }

    /// Design 27 for a lost connection; other failures keep their error card.
    @ViewBuilder
    private func failed(_ error: AppError) -> some View {
        if error == .mirroringNetworkLost {
            VStack(spacing: Spacing.m) {
                Image(ArtAsset.connectionLost.rawValue)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 260, maxHeight: 170)
                    .accessibilityHidden(true)
                Text(L10n.tr("v2.error.connectionLost"))
                    .font(.appScreenTitle)
                    .foregroundStyle(Color.appTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let name = mirroring.deviceID.flatMap({ model.devices.device($0)?.displayName }) {
                    Text(L10n.tr("v2.error.lostDevice", name))
                        .font(.appBody)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Label { Text(L10n.tr("pairing.step.keepOn")) } icon: { AppIconView("icon-check-circle", size: 22).foregroundStyle(Color.appAccent) }
                    Label { Text(L10n.tr("connection.lost.sameWifi")) } icon: { AppIconView("icon-check-circle", size: 22).foregroundStyle(Color.appAccent) }
                }
                .font(.appBody)
                .foregroundStyle(Color.appTextPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    mirroring.acknowledgeEnd()
                    if let device = model.devices.selectedDevice, !model.connection.state.isConnected { model.connection.connect(to: device) }
                } label: {
                    Label { Text(L10n.tr("v2.error.reconnect")) } icon: { ButtonIcon("icon-refresh") }
                }
                .buttonStyle(.primary)
                Button {
                    mirroring.acknowledgeEnd()
                    model.sheet = .discovery
                } label: {
                    Label { Text(L10n.tr("v2.error.otherTV")) } icon: { ButtonIcon("icon-tv") }
                }
                .buttonStyle(.secondary)
                Button(L10n.tr("common.getHelp")) { model.present(.help("mirroringProblem")) }
                    .buttonStyle(.textAction)
                InfoNote(text: L10n.tr("v2.error.paused"), boxed: true)
            }
            .frame(maxWidth: .infinity)
        } else {
            ErrorCard(error: error, feature: "mirroring") { action in
                if action == .retry || action == .showSetupSteps { mirroring.acknowledgeEnd() }
            }
            Button(L10n.tr("mirroring.backToSetup")) { mirroring.acknowledgeEnd() }
                .buttonStyle(.secondary)
        }
    }
}

extension MirroringQuality {
    var title: String {
        switch self {
        case .auto: L10n.tr("v2.mirror.auto")
        case .high: L10n.tr("v2.mirror.high")
        case .dataSaver: L10n.tr("v2.mirror.dataSaver")
        }
    }

    var detail: String {
        switch self {
        case .auto: L10n.tr("v2.mirror.autoDescription")
        case .high: L10n.tr("v2.mirror.highDescription")
        case .dataSaver: L10n.tr("v2.mirror.saverDescription")
        }
    }
}

/// Design 45: picture profile. The choice applies to the running session right away.
struct MirroringQualityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                PageHeader(title: L10n.tr("v2.mirror.qualityTitle"))
                Text(L10n.tr("mirroring.quality.lead"))
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                    .padding(.bottom, Spacing.xs)
                ForEach(MirroringQuality.allCases, id: \.self) { option in
                    let selected = model.mirroring.quality == option
                    Button {
                        Haptics.selection()
                        model.mirroring.setQuality(option)
                    } label: {
                        HStack(spacing: Spacing.m) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                                Text(option.detail).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                            }
                            Spacer()
                            RadioIndicator(isOn: selected)
                        }
                        .surfaceCard(highlighted: selected)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                InfoNote(text: L10n.tr("v2.mirror.audioLocal") + ".", boxed: true)
                    .padding(.top, Spacing.xs)
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.l)
        }
        .appScreenBackground()
        .pageNavigation(L10n.tr("v2.mirror.qualityTitle"))
    }
}

private struct CheckRow: View {
    let icon: String
    let title: String
    let detail: String
    let ok: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            AppIconView(icon, size: 24).foregroundStyle(Color.appTextPrimary).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                Text(detail).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
            }
            Spacer(minLength: Spacing.xs)
            StatusBadge(kind: ok ? .ready : .attention, text: ok ? L10n.tr("v2.status.ready") : L10n.tr("mirroring.setup.notReady"))
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(minHeight: HitTarget.row)
        .accessibilityElement(children: .combine)
    }
}

private struct InfoLine: View {
    let icon: String
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: Spacing.s) {
            AppIconView(icon, size: 24).foregroundStyle(Color.appTextPrimary).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.appBody).foregroundStyle(Color.appTextPrimary)
                if let detail { Text(detail).font(.appFootnote).foregroundStyle(Color.appTextSecondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .accessibilityElement(children: .combine)
    }
}

/// Phone → TV illustration for the mirroring setup (native drawing with kit icons).
private struct MirrorArt: View {
    var body: some View {
        HStack(spacing: Spacing.s) {
            AppIconView("icon-phone", size: 70).foregroundStyle(Color.appTextPrimary)
            AppIconView("icon-cast", size: 30).foregroundStyle(Color.appAccent)
            ZStack {
                AppIconView("icon-tv", size: 130).foregroundStyle(Color.appTextPrimary)
                AppIconView("icon-photo", size: 46).foregroundStyle(Color.appAccent).offset(y: -8)
            }
        }
        .shadow(color: Color.appAccent.opacity(0.25), radius: 24)
        .accessibilityHidden(true)
    }
}

/// Apple's system broadcast button, limited to our extension. Our label is drawn on top and
/// passes touches through to the system control (which shows the consent prompt).
struct BroadcastStartButton: View {
    let title: String

    var body: some View {
        ZStack {
            BroadcastPickerRepresentable()
            HStack(spacing: Spacing.xs) {
                Text(title)
                AppIconView("icon-chevron-right", size: 18, relativeTo: .headline)
            }
                .font(.appHeadline)
                .foregroundStyle(Color.appOnAccent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appAccent, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct BroadcastPickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = MirroringShared.extensionBundleID
        picker.showsMicrophoneButton = false
        picker.accessibilityLabel = L10n.tr("mirroring.start")
        // Stretch the internal button over the whole area so the overlay label is tappable.
        for case let button as UIButton in picker.subviews {
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: picker.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: picker.trailingAnchor),
                button.topAnchor.constraint(equalTo: picker.topAnchor),
                button.bottomAnchor.constraint(equalTo: picker.bottomAnchor),
            ])
            button.imageView?.alpha = 0
            button.accessibilityLabel = L10n.tr("mirroring.start")
        }
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
