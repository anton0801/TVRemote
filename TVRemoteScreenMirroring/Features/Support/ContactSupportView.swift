import MessageUI
import PhotosUI
import SafariServices
import SwiftUI
import UIKit

/// Prepares a support request. The app never sends anything by itself: the user confirms in
/// Mail, their own mail app, or the web form. Opening a channel is not proof of delivery.
struct ContactSupportView: View {
    enum Channel: Hashable { case email, form, copyOnly }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let category: SupportCategory?
    let errorCode: String?
    let feature: String?

    @State private var channel: Channel = .copyOnly
    @State private var showPreview = false
    @State private var showMail = false
    @State private var showForm = false
    @State private var showFormNotice = false
    @State private var showDeleteConfirm = false
    @State private var notice: InlineNotice?
    @State private var screenshotItem: PhotosPickerItem?
    @State private var screenshot: Data?
    @FocusState private var focus: Field?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    enum Field: Hashable { case problem, expected, tvModel, email }

    struct InlineNotice: Equatable {
        var kind: InlineNoticeView.Kind
        var text: String
    }

    private var support: SupportService { model.support }

    private var availableChannels: [Channel] {
        var channels: [Channel] = []
        if support.hasEmailChannel { channels.append(.email) }
        if support.hasFormChannel { channels.append(.form) }
        return channels.isEmpty ? [.copyOnly] : channels
    }

    private var hasProblemText: Bool {
        !support.draft.problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var emailIsValid: Bool { SupportDraft.isPlausibleEmail(support.draft.contactEmail) }

    var body: some View {
        @Bindable var support = model.support
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                PageHeader(title: L10n.tr("v2.support.title"))
                Text(L10n.tr("v2.support.body"))
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                FormField(title: L10n.tr("v2.support.topic")) {
                    Menu {
                        Picker(L10n.tr("support.field.category"), selection: $support.draft.category) {
                            ForEach(SupportCategory.allCases) { category in
                                Text(L10n.tr("support.category.\(category.rawValue)")).tag(category)
                            }
                        }
                    } label: {
                        HStack(spacing: Spacing.s) {
                            Image(systemName: "bubble.left")
                                .font(.title3)
                                .foregroundStyle(Color.appAccent)
                                .accessibilityHidden(true)
                            Text(L10n.tr("support.category.\(support.draft.category.rawValue)"))
                                .font(.appBodyEmphasis)
                                .foregroundStyle(Color.appTextPrimary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: Spacing.xs)
                            AppIconView("icon-chevron-right", size: 16).foregroundStyle(Color.appTextSecondary)
                        }
                        .fieldChrome()
                    }
                    .accessibilityLabel(L10n.tr("support.field.category"))
                    .accessibilityValue(L10n.tr("support.category.\(support.draft.category.rawValue)"))
                }

                FormField(title: L10n.tr("v2.support.message"), footer: hasProblemText ? nil : L10n.tr("support.field.problem.required")) {
                    VStack(alignment: .trailing, spacing: Spacing.xs) {
                        TextField(L10n.tr("support.field.problem.placeholder"), text: $support.draft.problem, axis: .vertical)
                            .lineLimit(5...12)
                            .focused($focus, equals: .problem)
                            .accessibilityIdentifier("support.problem")
                        Text(verbatim: "\(support.draft.problem.count)/\(SupportService.maxProblemLength)")
                            .font(.appCaption.monospacedDigit())
                            .foregroundStyle(Color.appTextSecondary)
                            .accessibilityLabel(L10n.tr("keyboard.counter.accessibility", support.draft.problem.count, SupportService.maxProblemLength))
                    }
                    .fieldChrome(focused: focus == .problem)
                }

                FormField(title: L10n.tr("support.field.tvModel"), footer: L10n.tr("support.field.tvModel.footer")) {
                    TextField(L10n.tr("support.field.tvModel.placeholder"), text: $support.draft.tvModel, axis: .vertical)
                        .lineLimit(1...3)
                        .textInputAutocapitalization(.characters)
                        .focused($focus, equals: .tvModel)
                        .fieldChrome(focused: focus == .tvModel)
                }

                if support.hasFormChannel {
                    FormField(title: L10n.tr("support.field.contactEmail"),
                              footer: emailIsValid ? L10n.tr("support.field.contactEmail.footer") : L10n.tr("support.field.contactEmail.invalid"),
                              footerIsError: !emailIsValid) {
                        TextField(L10n.tr("support.field.contactEmail.placeholder"), text: $support.draft.contactEmail)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .email)
                            .fieldChrome(focused: focus == .email)
                    }
                }

                attachmentSection
                diagnosticsSection

                if !support.isConfigured {
                    InlineNoticeView(kind: .warning, text: L10n.tr("support.notConfigured"))
                }

                secondaryActions
                if dynamicTypeSize.isAccessibilitySize {
                    // Very large text: the footer scrolls with the form instead of covering it.
                    Text(L10n.tr("support.send.footer", replyLanguages))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.vertical, Spacing.s)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .appScreenBackground()
        .pageNavigation(L10n.tr("v2.support.title"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.tr("common.close")) {
                    support.saveDraft()
                    dismiss()
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.tr("common.done")) { focus = nil }
            }
        }
        .onAppear {
            support.start(category: category, errorCode: errorCode, feature: feature)
            if !availableChannels.contains(channel) { channel = availableChannels[0] }
        }
        .onChange(of: support.draft) { _, draft in
            // Caps keep typing smooth and mail links valid; saving is debounced.
            if draft.problem.count > SupportService.maxProblemLength {
                support.draft.problem = String(draft.problem.prefix(SupportService.maxProblemLength))
            }
            if draft.expected.count > SupportService.maxExpectedLength {
                support.draft.expected = String(draft.expected.prefix(SupportService.maxExpectedLength))
            }
            support.scheduleSave()
        }
        .onDisappear { support.saveDraft() }
        .onChange(of: notice) { _, notice in
            // Status lines (copied, sent to Mail, errors) are announced to VoiceOver users.
            if let notice { AccessibilityNotification.Announcement(notice.text).post() }
        }
        .onChange(of: channel) { _, _ in notice = nil }
        .onChange(of: screenshotItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                // Removed or replaced while loading: drop this result.
                guard screenshotItem == item else { return }
                if let data {
                    screenshot = data
                } else {
                    screenshotItem = nil
                    notice = InlineNotice(kind: .warning, text: L10n.tr("support.screenshot.failed"))
                }
            }
        }
        .sheet(isPresented: $showPreview) {
            DiagnosticsPreview(diagnostics: diagnostics())
        }
        .sheet(isPresented: $showMail) {
            MailComposer(recipient: support.configuration.supportEmail, subject: support.subject, body: composedBody(), attachment: screenshot) { result in
                showMail = false
                // Delivery cannot be confirmed; we only report what Mail told us.
                switch result {
                case .sent:
                    notice = InlineNotice(kind: .success, text: L10n.tr("support.mail.handedOff"))
                    // Handed to Mail: the local copy isn't needed any more.
                    support.deleteDraft()
                    screenshot = nil
                    screenshotItem = nil
                case .saved: notice = InlineNotice(kind: .info, text: L10n.tr("support.mail.saved"))
                case .failed: notice = InlineNotice(kind: .error, text: L10n.tr("support.mail.failed"))
                default: notice = nil
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showForm, onDismiss: {
            // Returning from the browser proves nothing about submission.
            notice = InlineNotice(kind: .info, text: L10n.tr("support.form.returned"))
        }) {
            if let url = support.configuration.supportFormURL {
                SafariView(url: url).ignoresSafeArea()
            }
        }
        .alert(L10n.tr("support.form.noticeTitle"), isPresented: $showFormNotice) {
            Button(L10n.tr("support.form.copyAndOpen")) {
                if screenshot != nil {
                    notice = InlineNotice(kind: .info, text: L10n.tr("support.screenshot.notSent"))
                }
                UIPasteboard.general.string = composedBody()
                model.analytics.log(.supportChannelSelected(channel: .webForm))
                model.bonus.expectReturn()
                showForm = true
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("support.form.notice"))
        }
        .confirmationDialog(L10n.tr("support.deleteDraft.confirm"), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(L10n.tr("support.deleteDraft"), role: .destructive) {
                support.deleteDraft()
                screenshot = nil
                screenshotItem = nil
                notice = InlineNotice(kind: .info, text: L10n.tr("support.draftDeleted"))
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        }
    }

    // MARK: Sections

    private var attachmentSection: some View {
        FormField(title: nil, footer: L10n.tr("support.screenshot.footer")) {
            if let screenshot, let image = UIImage(data: screenshot) {
                HStack(spacing: Spacing.s) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                    Text(L10n.tr("support.screenshot.attached"))
                        .font(.appBody)
                        .foregroundStyle(Color.appTextPrimary)
                    Spacer(minLength: Spacing.xs)
                    Button(role: .destructive) {
                        self.screenshot = nil
                        screenshotItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.appTextSecondary)
                            .frame(width: HitTarget.minimum, height: HitTarget.minimum)
                    }
                    .accessibilityLabel(L10n.tr("support.screenshot.remove"))
                }
                .fieldChrome()
            } else {
                PhotosPicker(selection: $screenshotItem, matching: .screenshots) {
                    HStack(spacing: Spacing.s) {
                        AppIconView("icon-attachment", size: 24).foregroundStyle(Color.appAccent)
                        Text(L10n.tr("v2.support.attachment"))
                            .font(.appBodyEmphasis)
                            .foregroundStyle(Color.appTextPrimary)
                        Spacer(minLength: 0)
                    }
                    .fieldChrome()
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        @Bindable var support = model.support
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Toggle(isOn: $support.draft.includeDiagnostics) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("v2.support.diagnostics")).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                    Text(L10n.tr("support.diagnostics.detail")).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Color.appAccent)
            Button {
                model.analytics.log(.diagnosticPreviewed)
                showPreview = true
            } label: {
                HStack(spacing: Spacing.xxs) {
                    Text(L10n.tr("v2.support.review")).underline()
                    AppIconView("icon-chevron-right", size: 12, relativeTo: .subheadline)
                }
                .font(.appSecondary.weight(.medium))
                .foregroundStyle(Color.appAccent)
                .frame(minHeight: HitTarget.minimum)
            }
            .buttonStyle(.plain)
            Text(L10n.tr("v2.support.noPrivate") + " " + L10n.tr("support.diagnostics.footer"))
                .font(.appFootnote)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var secondaryActions: some View {
        SettingsGroup(title: L10n.tr("support.more"), footer: L10n.tr("support.draft.footer", support.configuration.supportDraftRetentionDays)) {
            Button {
                UIPasteboard.general.string = composedBody()
                notice = InlineNotice(kind: .success, text: L10n.tr("support.copied.text"))
                model.analytics.log(.supportChannelSelected(channel: .copy))
            } label: {
                SettingsRowLabel(symbol: "doc.on.clipboard", title: L10n.tr("support.channel.copyText"), accessory: .none)
            }
            .buttonStyle(.plain)
            if support.hasEmailChannel {
                SettingsDivider()
                Button {
                    UIPasteboard.general.string = support.configuration.supportEmail
                    notice = InlineNotice(kind: .success, text: L10n.tr("support.copied.address"))
                } label: {
                    SettingsRowLabel(symbol: "at", title: L10n.tr("support.channel.copyAddress"), accessory: .none)
                }
                .buttonStyle(.plain)
            }
            SettingsDivider()
            Button {
                showDeleteConfirm = true
            } label: {
                SettingsRowLabel(symbol: "trash", title: L10n.tr("support.deleteDraft"), accessory: .none, tint: .appDanger)
            }
            .buttonStyle(.plain)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: Spacing.xs) {
            if let notice {
                InlineNoticeView(kind: notice.kind, text: notice.text)
                    .transition(.opacity)
            }
            if support.hasEmailChannel {
                Button { perform(.email) } label: {
                    Label { Text(L10n.tr("v2.support.email")) } icon: { ButtonIcon("icon-mail") }
                }
                .buttonStyle(.primary)
                .disabled(!hasProblemText)
                .accessibilityIdentifier("support.primary")
            }
            if support.hasFormChannel {
                Button { perform(.form) } label: {
                    Label { Text(L10n.tr("v2.support.form")) } icon: { ButtonIcon("icon-external-link") }
                }
                .buttonStyle(support.hasEmailChannel ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
                .disabled(!hasProblemText || !emailIsValid)
                .accessibilityIdentifier(support.hasEmailChannel ? "support.form" : "support.primary")
            }
            if !support.isConfigured {
                Button(L10n.tr("support.channel.copyText")) { perform(.copyOnly) }
                    .buttonStyle(.primary)
                    .disabled(!hasProblemText)
                    .accessibilityIdentifier("support.primary")
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Text(L10n.tr("support.send.footer", replyLanguages))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.xs)
        .background(Color.appBackground.ignoresSafeArea(edges: .bottom))
    }

    private var replyLanguages: String {
        support.configuration.supportReplyLanguages
            .map { Locale(identifier: L10n.languageCode).localizedString(forLanguageCode: $0) ?? $0 }
            .joined(separator: ", ")
    }

    // MARK: Actions

    private func perform(_ selected: Channel) {
        channel = selected
        focus = nil
        notice = nil
        switch selected {
        case .email: sendEmail()
        case .form: showFormNotice = true
        case .copyOnly:
            UIPasteboard.general.string = composedBody()
            notice = InlineNotice(kind: .success, text: L10n.tr("support.copied.text"))
            model.analytics.log(.supportChannelSelected(channel: .copy))
        }
    }

    private func diagnostics() -> SupportDiagnostics {
        support.diagnostics(platform: model.connection.session?.platform ?? model.devices.selectedDevice?.platform, access: model.entitlements.state)
    }

    private func composedBody() -> String {
        support.composedBody(diagnostics: support.draft.includeDiagnostics ? diagnostics() : nil)
    }

    private func sendEmail() {
        model.analytics.log(.supportChannelSelected(channel: .email))
        model.bonus.expectReturn()
        if MFMailComposeViewController.canSendMail() {
            showMail = true
        } else if let url = support.mailtoURL(body: composedBody()) {
            // No Apple Mail account: hand the link to whatever mail app the user has (Gmail,
            // Outlook…). `canOpenURL` would need the scheme declared, so the open result decides.
            let hadScreenshot = screenshot != nil
            UIApplication.shared.open(url) { opened in
                if opened {
                    notice = InlineNotice(kind: .info, text: L10n.tr(hadScreenshot ? "support.mail.external.noScreenshot" : "support.mail.external"))
                } else {
                    notice = InlineNotice(kind: .warning, text: L10n.tr("support.mail.unavailable"))
                }
            }
        } else {
            notice = InlineNotice(kind: .warning, text: L10n.tr("support.mail.unavailable"))
        }
    }
}

/// Label above a control, optional footnote below.
private struct FormField<Content: View>: View {
    let title: String?
    var footer: String?
    var footerIsError = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let title {
                Text(title)
                    .font(.appHeadline)
                    .foregroundStyle(Color.appTextPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            content()
            if let footer {
                Text(footer)
                    .font(.appFootnote)
                    .foregroundStyle(footerIsError ? Color.appDanger : Color.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private extension View {
    /// Filled field background with a focus outline.
    func fieldChrome(focused: Bool = false) -> some View {
        self
            .font(.appBody)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .frame(minHeight: 52)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .stroke(focused ? Color.appAccentFill : Color.appBorder.opacity(0.8), lineWidth: focused ? 1.5 : 1)
            )
    }
}

private struct DiagnosticsPreview: View {
    let diagnostics: SupportDiagnostics
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.tr("support.diagnostics.previewIntro"))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                }
                Section {
                    ForEach(Array(diagnostics.lines().enumerated()), id: \.offset) { _, line in
                        Text(line).font(.appCaption.monospaced())
                    }
                }
                Section {
                    Text(L10n.tr("support.diagnostics.excluded"))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                }
            }
            .navigationTitle(L10n.tr("support.diagnostics.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.done")) { dismiss() }
                }
            }
        }
    }
}

struct MailComposer: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    var attachment: Data?
    let onFinish: (MFMailComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([recipient])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        if let attachment {
            let jpeg = UIImage(data: attachment)?.jpegData(compressionQuality: 0.8) ?? attachment
            controller.addAttachmentData(jpeg, mimeType: "image/jpeg", fileName: "screenshot.jpg")
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (MFMailComposeResult) -> Void
        init(onFinish: @escaping (MFMailComposeResult) -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish(result)
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
