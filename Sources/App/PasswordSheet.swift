import AppKit

/// Modal sheet that asks the user for a credential in response to an
/// OCaml-driven Remote.openConnectionPrompt. The prompt text comes straight
/// from Unison (often "password for user@host:" or similar) so we just
/// display it verbatim — sometimes it's a yes/no question (host key auth),
/// hence the editable text field rather than a secure-only field.
///
/// Two ways to dismiss: typing a response + clicking OK (or Enter), or
/// Cancel. The completion gets the response (or nil for cancel).
@MainActor
final class PasswordSheet: NSWindowController {

    typealias Completion = (_ response: String?) -> Void

    private let prompt: String
    private let isPassword: Bool
    private let onComplete: Completion
    private let textField: NSTextField

    init(prompt: String, onComplete: @escaping Completion) {
        self.prompt = prompt
        // Treat as secure entry unless the prompt looks like a yes/no host-key
        // question (the legacy app sniffs "are you sure" / "authenticity").
        let lower = prompt.lowercased()
        self.isPassword = !(lower.contains("authenticity")
                          || lower.contains("yes/no")
                          || lower.contains("(yes/no)"))
        self.onComplete = onComplete

        self.textField = isPassword ? NSSecureTextField() : NSTextField()

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
        textField.placeholderString = isPassword ? "Password" : "Response"

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
