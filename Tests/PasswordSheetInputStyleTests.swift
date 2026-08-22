import XCTest
import AppKit
@testable import unison_ui_mac

/// Two narrow real-AppKit assertions that `PasswordSheet` renders the response
/// field per its typed `InputStyle`. Pure classifier tests can't catch a reversed
/// ternary in `PasswordSheet` or a caller passing the wrong style — this wiring
/// check does. (The prompt classification itself is covered, without AppKit, in
/// `ConnectPromptClassifierTests`.)
@MainActor
final class PasswordSheetInputStyleTests: XCTestCase {

    /// Whether the sheet's window contains a masked NSSecureTextField anywhere
    /// (the prompt label and a plain response field are ordinary NSTextFields, so
    /// only a secure *response* field makes this true).
    private func hasSecureField(_ sheet: PasswordSheet) -> Bool {
        guard let root = sheet.window?.contentView else { return false }
        func search(_ v: NSView) -> Bool {
            for sub in v.subviews {
                if sub is NSSecureTextField { return true }
                if search(sub) { return true }
            }
            return false
        }
        return search(root)
    }

    func test_secureCredentialStyle_usesSecureTextField() {
        let sheet = PasswordSheet(prompt: "user@host's password:",
                                  style: .secureCredential) { _ in }
        XCTAssertTrue(hasSecureField(sheet),
                      ".secureCredential must render a masked NSSecureTextField")
    }

    func test_plainResponseStyle_usesPlainTextField() {
        let sheet = PasswordSheet(
            prompt: "Are you sure you want to continue connecting (yes/no)?",
            style: .plainResponse) { _ in }
        XCTAssertFalse(hasSecureField(sheet),
                       ".plainResponse must NOT render a masked field")
    }

    // MARK: the verdict -> style mapping (the security-critical decision itself)

    func test_inputStyle_forCredential_isSecure() {
        XCTAssertEqual(PasswordSheet.InputStyle(for: .credential), .secureCredential)
    }

    func test_inputStyle_forHostKeyQuestion_isPlain() {
        XCTAssertEqual(PasswordSheet.InputStyle(for: .hostKeyQuestion), .plainResponse)
    }

    func test_inputStyle_forFatalAndRetry_isNil() {
        XCTAssertNil(PasswordSheet.InputStyle(for: .fatal(reason: "boom")))
        XCTAssertNil(PasswordSheet.InputStyle(for: .retryNotice("Permission denied, please try again.")))
    }
}
