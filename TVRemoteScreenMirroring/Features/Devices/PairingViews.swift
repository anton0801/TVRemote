import SwiftUI

/// Shows the TV pairing prompt (confirm on TV / enter PIN) wherever a connection starts.
struct PairingPromptModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    /// Only one place may present the prompt: the root when nothing covers it, otherwise the
    /// top-most sheet (a view that is already presenting can't present another sheet).
    /// Evaluated live, so a dismissal caused by hosting moving elsewhere never cancels pairing.
    var isHost: @MainActor () -> Bool = { true }

    func body(content: Content) -> some View {
        let pairing = model.connection.pairing
        content.sheet(isPresented: Binding(
            get: { isHost() && pairing.prompt != .none },
            set: { presented in
                // The user closed the prompt (not: another view took over presenting it).
                if !presented, isHost(), pairing.prompt != .none { model.connection.cancelConnecting() }
            }
        )) {
            PairingSheet()
                .environment(model)
                .presentationDetents([.large])
                .interactiveDismissDisabled(false)
        }
    }
}

/// Pairing (design 08: code from the TV; design 37: allow on the TV). "Connected" appears only
/// after the TV answers; the user can always request again, pick another TV or get help.
private struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    @State private var pin = ""
    @FocusState private var pinFocused: Bool

    private var device: TVDevice? {
        model.connection.state.deviceID.flatMap { model.devices.device($0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.m) {
                    PageHeader(title: model.connection.pairing.prompt == .confirmOnTV ? L10n.tr("v2.pairing.allowTitle") : L10n.tr("v2.pairing.title"))
                    switch model.connection.pairing.prompt {
                    case .confirmOnTV, .none:
                        allowOnTV
                    case .enterPIN(let attempt):
                        enterCode(attempt: attempt)
                    }
                }
                .padding(.horizontal, Spacing.screen)
                .padding(.bottom, Spacing.l)
            }
            .appScreenBackground()
            .pageNavigation(model.connection.pairing.prompt == .confirmOnTV ? L10n.tr("v2.pairing.allowTitle") : L10n.tr("v2.pairing.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) { model.connection.cancelConnecting() }
                }
            }
        }
    }

    private var pendingCard: some View {
        HStack(spacing: Spacing.s) {
            AppIconView("icon-tv", size: 28).foregroundStyle(Color.appTextPrimary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(device?.displayName ?? L10n.tr("pairing.yourTV")).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                    Circle().fill(Color.appTextSecondary).frame(width: 8, height: 8).accessibilityHidden(true)
                }
                Text(verbatim: [device?.platform.shortName, L10n.tr("tv.status.awaitingApproval")].compactMap { $0 }.joined(separator: " · "))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .surfaceCard()
        .accessibilityElement(children: .combine)
    }

    // MARK: Allow on TV (37)

    @ViewBuilder
    private var allowOnTV: some View {
        pendingCard
        TVAllowArt()
            .frame(maxWidth: 300)
            .frame(height: 170)
            .accessibilityHidden(true)
        VStack(spacing: Spacing.xs) {
            Text(L10n.tr("v2.pairing.allowBody"))
                .font(.appBannerTitle)
                .foregroundStyle(Color.appTextPrimary)
                .multilineTextAlignment(.center)
            HStack(spacing: Spacing.xs) {
                ProgressView().tint(.appAccent)
                Text(L10n.tr("v2.pairing.waiting"))
                    .font(.appSecondary)
                    .foregroundStyle(Color.appTextSecondary)
            }
            .accessibilityElement(children: .combine)
        }
        VStack(alignment: .leading, spacing: Spacing.m) {
            NumberedStep(number: 1, icon: "icon-power", title: L10n.tr("pairing.step.keepOn"), detail: L10n.tr("pairing.step.keepOn.detail"))
            NumberedStep(number: 2, icon: "icon-remote", title: L10n.tr("pairing.step.accept"),
                         detail: L10n.tr("pairing.confirm.message", device?.displayName ?? L10n.tr("pairing.yourTV")))
        }
        .surfaceCard()
        Button {
            requestAgain()
        } label: {
            Label { Text(L10n.tr("v2.pairing.requestAgain")) } icon: { ButtonIcon("icon-refresh") }
        }
        .buttonStyle(.outline)
        escapeRow
    }

    // MARK: Code from the TV (08)

    @ViewBuilder
    private func enterCode(attempt: Int) -> some View {
        pendingCard
        Text(L10n.tr("pairing.pin.title"))
            .font(.appBannerTitle)
            .foregroundStyle(Color.appTextPrimary)
            .multilineTextAlignment(.center)
        Text(L10n.tr("pairing.pin.message"))
            .font(.appBody)
            .foregroundStyle(Color.appTextSecondary)
            .multilineTextAlignment(.center)
        if attempt > 1 {
            InlineNoticeView(kind: .error, text: L10n.tr("pairing.pin.retry"))
        }
        CodeBoxes(code: pin, length: 6)
            .overlay {
                // The real input: invisible field over the boxes, so taps focus it.
                TextField("", text: $pin)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .textContentType(.oneTimeCode)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .focused($pinFocused)
                    .onChange(of: pin) { _, value in
                        let filtered = String(value.uppercased().filter { $0.isHexDigit }.prefix(6))
                        if filtered != value { pin = filtered }
                    }
                    .accessibilityLabel(L10n.tr("pairing.pin.accessibility"))
                    .accessibilityValue(pin)
            }
            .onAppear { pinFocused = true; pin = "" }
            .onTapGesture { pinFocused = true }
        Text(L10n.tr("v2.pairing.keepOpen"))
            .font(.appFootnote)
            .foregroundStyle(Color.appTextSecondary)
            .multilineTextAlignment(.center)
        Button(L10n.tr("pairing.pin.submit")) {
            model.connection.pairing.submitPIN(pin)
            pin = ""
        }
        .buttonStyle(.primary)
        .disabled(pin.count != 6)
        .accessibilityIdentifier("pairing.submit")
        Button {
            requestAgain()
        } label: {
            Label { Text(L10n.tr("v2.pairing.newCode")) } icon: { ButtonIcon("icon-refresh") }
        }
        .buttonStyle(.secondary)
        InfoNote(text: L10n.tr("v2.pairing.allow"))
            .padding(.top, Spacing.xs)
    }

    private var escapeRow: some View {
        HStack(spacing: Spacing.xs) {
            Button {
                model.connection.cancelConnecting()
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    model.sheet = .discovery
                }
            } label: {
                Label { Text(L10n.tr("v2.error.otherTV")) } icon: { ButtonIcon("icon-tv") }
            }
            .buttonStyle(.secondary)
            Button {
                model.connection.cancelConnecting()
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    model.present(.help("cannotConnect"))
                }
            } label: {
                Label { Text(L10n.tr("v2.connection.help")) } icon: { ButtonIcon("icon-help") }
            }
            .buttonStyle(.secondary)
        }
    }

    /// Starts the TV's request (or a new code) again for the same TV.
    private func requestAgain() {
        guard let device else { return }
        pin = ""
        model.connection.pairAgain(device)
    }
}

/// Code boxes for the 6-character pairing code.
private struct CodeBoxes: View {
    let code: String
    let length: Int

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(0..<length, id: \.self) { index in
                let characters = Array(code)
                Text(verbatim: index < characters.count ? String(characters[index]) : " ")
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.appTextPrimary)
                    .frame(maxWidth: 52, minHeight: 60)
                    .frame(maxWidth: .infinity)
                    .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .stroke(index == characters.count ? Color.appAccent : Color.appBorder, lineWidth: index == characters.count ? 1.5 : 1))
            }
        }
        .accessibilityHidden(true)
    }
}

/// TV with an "Allow" request on screen (native drawing, no text from a raster).
private struct TVAllowArt: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(Palette.RGB(hex: 0x17181B)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.appBorder, lineWidth: 3))
                    .shadow(color: Color.appAccent.opacity(0.25), radius: 24)
                    .frame(width: w * 0.86, height: h * 0.82)
                    .position(x: w / 2, y: h * 0.43)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.appSurface)
                    .frame(width: w * 0.5, height: h * 0.46)
                    .overlay {
                        VStack(spacing: h * 0.045) {
                            AppIconView("icon-remote", size: 20).foregroundStyle(Color.appTextSecondary)
                            Capsule().fill(Color.appTextSecondary.opacity(0.5)).frame(width: w * 0.3, height: 4)
                            HStack(spacing: w * 0.03) {
                                Capsule().fill(Color.appSurfaceRaised).frame(width: w * 0.13, height: h * 0.09)
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.appAccent, lineWidth: 1.5)
                                    .frame(width: w * 0.2, height: h * 0.11)
                            }
                        }
                    }
                    .position(x: w / 2, y: h * 0.43)
                Rectangle().fill(Color.appBorder).frame(width: w * 0.04, height: h * 0.08).position(x: w / 2, y: h * 0.88)
                Capsule().fill(Color.appBorder).frame(width: w * 0.3, height: 4).position(x: w / 2, y: h * 0.93)
            }
        }
    }
}

/// Separate, evidence-based results for each capability (design 09, spec §4, §6). Nothing is
/// called "Ready" without the check's evidence.
struct CompatibilityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onDone: (() -> Void)?

    private var remoteReady: Bool { model.checker.capabilities[.remoteControl].support == .supported }

    var body: some View {
        let checker = model.checker
        ScrollView {
            VStack(spacing: Spacing.m) {
                PageHeader(title: remoteReady ? L10n.tr("v2.compatibility.title") : L10n.tr("compat.title"))
                if model.connection.connectedDevice != nil {
                    TVStatusCard(showsMenu: false)
                    VStack(spacing: 0) {
                        ForEach(Array(Capability.userFacing.enumerated()), id: \.element) { index, capability in
                            if index > 0 { Divider().overlay(Color.appBorder).padding(.leading, 56) }
                            CapabilityRow(capability: capability, state: checker.capabilities[capability],
                                          isChecking: checker.phase == .running && checker.capabilities[capability].support == .unknown)
                        }
                    }
                    .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Color.appBorder.opacity(0.7), lineWidth: 1))
                    Text(L10n.tr("v2.compatibility.note"))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                } else {
                    StateMessageView(art: ArtAsset.connectionLost.rawValue, title: L10n.tr("compat.notConnected.title"),
                                     message: L10n.tr("compat.notConnected.message"),
                                     primaryTitle: L10n.tr("v2.discovery.title"), primaryAction: { model.sheet = .discovery })
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.m)
        }
        .safeAreaInset(edge: .bottom) {
            if model.connection.connectedDevice != nil {
                VStack(spacing: Spacing.xs) {
                    Button {
                        finish()
                        model.selectedTab = .remote
                    } label: {
                        Label { Text(L10n.tr("v2.compatibility.try")) } icon: { ButtonIcon("icon-remote") }
                    }
                    .buttonStyle(.primary)
                    .accessibilityIdentifier("compat.continue")
                    if checker.capabilities[.screenMirroring].support != .unsupported {
                        Button {
                            finish()
                            model.openCast(.mirroring)
                        } label: {
                            Label { Text(L10n.tr("compat.setupMirroring")) } icon: { ButtonIcon("icon-cast") }
                        }
                        .buttonStyle(.secondary)
                    }
                    Text(L10n.tr("v2.compatibility.free"))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Spacing.screen)
                .padding(.vertical, Spacing.s)
                .background(Color.appBackground.ignoresSafeArea(edges: .bottom))
            }
        }
        .appScreenBackground()
        .pageNavigation(remoteReady ? L10n.tr("v2.compatibility.title") : L10n.tr("compat.title"))
        .toolbar {
            if onDone == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.done")) { dismiss() }
                }
            }
        }
    }

    private func finish() {
        if let onDone { onDone() } else { dismiss() }
    }
}

struct CapabilityRow: View {
    let capability: Capability
    let state: CapabilityState
    var isChecking = false

    private var icon: String {
        switch capability {
        case .remoteControl: "icon-remote"
        case .textInput: "icon-keyboard"
        case .appLaunch: "icon-apps"
        case .photos: "icon-photo"
        case .video: "icon-video"
        case .screenMirroring: "icon-cast"
        case .powerOff: "icon-power"
        case .wakeOnNetwork: "icon-wake"
        }
    }

    private var badge: StatusBadge {
        if isChecking { return StatusBadge(kind: .neutral, text: L10n.tr("capability.status.checking")) }
        switch state.support {
        case .supported: return StatusBadge(kind: .ready, text: L10n.tr("v2.status.ready"))
        case .limited: return StatusBadge(kind: .attention, text: L10n.tr("capability.status.limited"))
        case .unsupported: return StatusBadge(kind: .neutral, text: L10n.tr("capability.status.unsupported"))
        case .unknown: return StatusBadge(kind: .neutral, text: L10n.tr("capability.status.unknown"))
        }
    }

    private func title(wraps: Bool) -> some View {
        Text(L10n.tr("capability.\(capability.rawValue)"))
            .font(.appHeadline)
            .foregroundStyle(Color.appTextPrimary)
            .fixedSize(horizontal: !wraps, vertical: true)
    }

    @ViewBuilder
    private var status: some View {
        if isChecking { ProgressView().controlSize(.small) } else { badge.fixedSize() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .top, spacing: Spacing.s) {
                AppIconView(icon, size: 26).foregroundStyle(Color.appAccent).frame(width: 32)
                // Title and status on one line when they fit, status under the title otherwise.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.xs) {
                        title(wraps: false)
                        Spacer(minLength: Spacing.xs)
                        status
                    }
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        title(wraps: true)
                        status
                    }
                }
            }
            ForEach(state.notes.filter { $0 != .airPlayAvailable }, id: \.self) { note in
                Text(L10n.tr("capability.note.\(note.rawValue)"))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 44)
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(minHeight: HitTarget.row)
        .accessibilityElement(children: .combine)
    }
}

/// A TV switch waiting for the user's confirmation (mirroring or casting would stop).
struct PendingTVSwitch {
    let connect: @MainActor () -> Void
}

/// Same confirmation wherever the user can pick another TV.
struct SwitchTVConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var pending: PendingTVSwitch?

    func body(content: Content) -> some View {
        content.confirmationDialog(L10n.tr("header.switch.mirroring.title"),
                                   isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                                   titleVisibility: .visible) {
            Button(L10n.tr("header.switch.mirroring.confirm"), role: .destructive) {
                if let pending { model.confirmSwitch(connect: pending.connect) }
                pending = nil
            }
            Button(L10n.tr("common.cancel"), role: .cancel) { pending = nil }
        } message: {
            Text(L10n.tr("header.switch.mirroring.message"))
        }
    }
}
