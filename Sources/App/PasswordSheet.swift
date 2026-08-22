import AppKit

/// Modal sheet that asks the user for a credential in response to an
/// OCaml-driven Remote.openConnectionPrompt. The prompt text comes straight
/// from Unison and is displayed verbatim; whether the response field is masked
/// is the caller's typed decision (`InputStyle`), NOT sniffed from the prompt
/// here — the `ConnectPromptClassifier` verdict is the single source of truth.
///
/// Two ways to dismiss: typing a response + clicking OK (or Enter), or
/// Cancel. The completion gets the response (or nil for cancel).
@MainActor
final class PasswordSheet: NSWindowController {

    typealias Completion = (_ response: String?) -> Void

    /// How the response field is presented.
    enum InputStyle: Equatable {
        /// A secret — password / passphrase / MFA / PAM — shown masked.
        case secureCredential
        /// A non-secret answer (a host-key yes/no question), shown editable.
        case plainResponse

        /// The one place the security-critical mapping lives: a classifier verdict
        /// that produces a prompt sheet becomes a field style. `nil` for verdicts
        /// that never build a sheet (`.fatal` / `.retryNotice`), so a caller can't
        /// accidentally show a field for them. Tested directly, because the
        /// mapping — not just the rendering — is what must not silently invert.
        init?(for verdict: ConnectPromptClassifier.Verdict) {
            switch verdict {
            case .credential:      self = .secureCredential
            case .hostKeyQuestion: self = .plainResponse
            case .fatal, .retryNotice: return nil
            }
        }
    }

    private let prompt: String
    private let onComplete: Completion
    private let textField: NSTextField

    init(prompt: String, style: InputStyle, onComplete: @escaping Completion) {
        self.prompt = prompt
        self.onComplete = onComplete
        // No prompt sniffing here: the field style is the caller's typed decision
        // from ConnectPromptClassifier. A secure (masked) field is the fail-safe
        // default the caller falls back to for anything not a recognized host-key
        // question.
        self.textField = style == .secureCredential ? NSSecureTextField() : NSTextField()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.titled],
            backing: .buffered, defer: false
        )
        window.title = "Authenticate"
        super.init(window: window)
        configure()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    private func configure() {
        guard let contentView = window?.contentView else { return }

        let promptLabel = NSTextField(wrappingLabelWithString: prompt)
        promptLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        promptLabel.lineBreakMode = .byWordWrapping
        promptLabel.maximumNumberOfLines = 0

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.placeholderString = (textField is NSSecureTextField) ? "Password" : "Response"

        let okButton = NSButton(title: "OK", target: self, action: #selector(okClicked))
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape

        let buttonRow = NSStackView(views: [NSView(), cancelButton, okButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let stack = NSStackView(views: [promptLabel, textField, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            textField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            promptLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])

        window?.initialFirstResponder = textField
    }

    func runAsSheet(over parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window) { _ in /* completion happens in our handlers */ }
        window.makeFirstResponder(textField)
    }

    @objc private func okClicked() {
        let response = textField.stringValue
        dismiss(with: response)
    }

    @objc private func cancelClicked() {
        dismiss(with: nil)
    }

    private func dismiss(with response: String?) {
        guard let window, let parent = window.sheetParent else {
            onComplete(response)
            return
        }
        parent.endSheet(window)
        onComplete(response)
    }
}
