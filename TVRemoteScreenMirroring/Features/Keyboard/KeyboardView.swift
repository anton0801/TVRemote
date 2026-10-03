import SwiftUI
import UIKit

/// TV keyboard (design 10). Live modes mirror the field to the TV as you type; Samsung's
/// send-completed mode sends the text once. Nothing is reported as delivered without the TV's
/// answer.
struct KeyboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    static let maxLength = 500

    private var controller: TextInputController { model.text }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                PageHeader(title: L10n.tr("v2.keyboard.title"))
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    if let device = model.devices.selectedDevice {
                        Text(device.displayName)
                            .font(.appBody)
                            .foregroundStyle(Color.appTextSecondary)
                    }
                }
                if let mode = controller.mode {
                    hint(for: mode)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(L10n.tr("v2.keyboard.label"))
                            .font(.appFootnote)
                            .foregroundStyle(Color.appTextSecondary)
                        ComposingTextField(text: $draft, placeholder: L10n.tr("keyboard.placeholder"), maxLength: Self.maxLength) { text, composing in
                            controller.update(text, isComposing: composing)
                        } onReturn: {
                            controller.submit()
                        }
                        .frame(minHeight: 44)
                        .accessibilityLabel(L10n.tr("keyboard.field.accessibility"))
                        Spacer(minLength: Spacing.l)
                        Text(verbatim: "\(draft.count)/\(Self.maxLength)")
                            .font(.appCaption.monospacedDigit())
                            .foregroundStyle(Color.appTextSecondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .accessibilityLabel(L10n.tr("keyboard.counter.accessibility", draft.count, Self.maxLength))
                    }
                    .surfaceCard()

                    statusView

                    if mode.isLive {
                        // Live modes keep the TV field in sync, so deleting here deletes on the TV.
                        Button {
                            draft = ""
                            controller.clear()
                        } label: {
                            Label { Text(L10n.tr("v2.keyboard.deleteTV")) } icon: { ButtonIcon("icon-tv") }
                        }
                        .buttonStyle(.secondary)
                        .disabled(draft.isEmpty)
                        Button {
                            controller.submit()
                        } label: {
                            Label { Text(L10n.tr("keyboard.search")) } icon: { ButtonIcon("icon-send") }
                        }
                        .buttonStyle(.primary)
                        .disabled(controller.status == .sending)
                    } else {
                        Button {
                            draft = ""
                            controller.clear()
                        } label: {
                            Label { Text(L10n.tr("v2.keyboard.clear")) } icon: { ButtonIcon("icon-trash") }
                        }
                        .buttonStyle(.secondary)
                        .disabled(draft.isEmpty)
                        Button {
                            controller.submit()
                        } label: {
                            Label { Text(L10n.tr("v2.keyboard.send")) } icon: { ButtonIcon("icon-send") }
                        }
                        .buttonStyle(.primary)
                        .disabled(draft.isEmpty || controller.status == .sending)
                        .accessibilityIdentifier("keyboard.send")
                    }
                    Text(L10n.tr("keyboard.privacyNote"))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                } else {
                    StateMessageView(systemImage: "icon-keyboard", title: L10n.tr("keyboard.unsupported.title"),
                                     message: L10n.tr("keyboard.unsupported.message"),
                                     primaryTitle: L10n.tr("keyboard.useButtons"), primaryAction: { dismiss() })
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.l)
        }
        .scrollDismissesKeyboard(.never)
        .appScreenBackground()
        .pageNavigation(L10n.tr("v2.keyboard.title"))
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            controller.begin()
            draft = controller.text
        }
    }

    @ViewBuilder
    private func hint(for mode: TextInputMode) -> some View {
        switch controller.textFieldState {
        case .focused:
            InlineNoticeView(kind: .success, text: L10n.tr("keyboard.fieldActive"))
        case .notFocused:
            InlineNoticeView(kind: .info, text: L10n.tr("v2.keyboard.instruction"))
        case .unknown:
            Text(L10n.tr(mode == .sendCompleted ? "keyboard.hint.sendCompleted" : "v2.keyboard.instruction"))
                .font(.appBody)
                .foregroundStyle(Color.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch controller.status {
        case .idle:
            EmptyView()
        case .sending:
            StatusBadge(kind: .neutral, text: L10n.tr("keyboard.status.sending"))
        case .synced:
            StatusBadge(kind: .ready, text: L10n.tr("keyboard.status.sent"))
        case .unknown:
            InlineNoticeView(kind: .warning, text: L10n.tr("keyboard.status.unknown"), actionTitle: L10n.tr("keyboard.resend")) {
                controller.resend()
            }
        case .failed(let error):
            ErrorCard(error: error, feature: "keyboard") { _ in dismiss() }
        }
    }
}

/// UITextField bridge that reports whether the keyboard is composing (marked text), so
/// incomplete compositions are not sent to the TV as separate fragments.
struct ComposingTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var maxLength = Int.max
    let onChange: (String, Bool) -> Void
    let onReturn: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.font = UIFont.preferredFont(forTextStyle: .title3)
        field.textColor = Palette.textPrimary.uiColor
        field.tintColor = Palette.accent.uiColor
        field.keyboardAppearance = .dark
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: Palette.textSecondary.uiColor.withAlphaComponent(0.7)])
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = .search
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.clearButtonMode = .never
        field.textContentType = .none
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        DispatchQueue.main.async { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        if field.text != text, field.markedTextRange == nil { field.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: ComposingTextField
        init(_ parent: ComposingTextField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            let value = field.text ?? ""
            parent.text = value
            parent.onChange(value, field.markedTextRange != nil)
        }

        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            // Marked (composing) text is always allowed; the limit applies to committed text.
            guard textField.markedTextRange == nil, let current = textField.text, let swiftRange = Range(range, in: current) else { return true }
            return current.replacingCharacters(in: swiftRange, with: string).count <= parent.maxLength
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onReturn()
            return false
        }
    }
}
