import XCTest
@testable import unison_ui_mac

/// L2 — one-shot `-ignorearchives` crash cleanup. The pure transform
/// `AppDelegate.contentByStrippingInjectedSuffix` removes the injected block
/// ONLY when the profile content ends with EXACTLY the app-owned suffix
/// (`ignoreArchivesInjectedSuffix`), restoring everything preceding it
/// character-for-character (the decoded Swift string content, including LF/CRLF
/// and trailing-newline structure — not raw bytes); it never scans for the
/// marker substring or an isolated marker line elsewhere. Injection and cleanup
/// share one suffix definition so they cannot drift.
final class IgnoreArchivesCleanupTests: XCTestCase {

    private typealias AD = AppDelegate
    private let suffix = AppDelegate.ignoreArchivesInjectedSuffix
    private let marker = AppDelegate.ignoreArchivesMarker

    /// Mirrors `rescanIgnoringArchives`'s injection exactly (shared suffix).
    private func inject(_ original: String) -> String { original + suffix }

    // MARK: - Restoration (exact, for every original shape)

    func test_intendedInjectedSuffix_isRemoved() {
        let original = "root = /a\nroot = ssh://h//b\n"
        let restored = AD.contentByStrippingInjectedSuffix(inject(original))
        XCTAssertEqual(restored, original)
    }

    func test_originalWithoutTrailingNewline_restoredExactly() {
        let original = "root = /a\nroot = /b"           // no trailing \n
        XCTAssertEqual(AD.contentByStrippingInjectedSuffix(inject(original)), original)
    }

    func test_originalWithLFTrailingAndBlankLines_restoredExactly() {
        let original = "root = /a\n\n# a comment\n\nroot = /b\n\n"
        XCTAssertEqual(AD.contentByStrippingInjectedSuffix(inject(original)), original)
    }

    func test_originalCRLF_restoredExactly() {
        let original = "root = /a\r\n# c\r\nroot = /b\r\n"   // CRLF throughout
        let restored = AD.contentByStrippingInjectedSuffix(inject(original))
        XCTAssertEqual(restored, original, "CRLF content preserved character-for-character")
    }

    // MARK: - No mutation for user content (never touch a user's own lines)

    func test_userCommentContainingMarkerSubstring_preserved() {
        // The marker text embedded inside a user comment, NOT the trailing block.
        let content = "# see the \(marker) note below\nroot = /a\n"
        XCTAssertNil(AD.contentByStrippingInjectedSuffix(content),
                     "a marker substring in a user comment must not trigger a rewrite")
    }

    func test_exactMarkerLineNotAtEOF_preserved_evenWithUserIgnorearchives() {
        // An exact marker line AND a genuine user `ignorearchives = true`, but
        // positioned so the document does NOT end with the app-owned suffix
        // (more content follows). Must be left untouched.
        let content = "\(marker)\nignorearchives = true\nroot = /a\nroot = /b\n"
        XCTAssertNil(AD.contentByStrippingInjectedSuffix(content),
                     "a marker/pref that isn't the trailing app block is a user's own content")
    }

    func test_noMarkerInput_returnsNoMutation() {
        XCTAssertNil(AD.contentByStrippingInjectedSuffix("root = /a\nroot = /b\n"))
        XCTAssertNil(AD.contentByStrippingInjectedSuffix(""))
    }

    // MARK: - Idempotence

    func test_secondPassAfterRestoration_returnsNoMutation() {
        let original = "root = /a\n"
        guard let restored = AD.contentByStrippingInjectedSuffix(inject(original)) else {
            return XCTFail("first pass should restore")
        }
        XCTAssertEqual(restored, original)
        XCTAssertNil(AD.contentByStrippingInjectedSuffix(restored),
                     "a second cleanup pass over the restored content is a no-op")
    }

    // MARK: - Shared definition (cannot drift)

    func test_injectedSuffix_isMarkerPlusPref_and_roundTrips() {
        XCTAssertTrue(suffix.contains(marker))
        XCTAssertTrue(suffix.hasSuffix("\nignorearchives = true\n"))
        XCTAssertTrue(suffix.hasPrefix("\n"))
        // Inject → strip round-trips to the exact original for an arbitrary body.
        let original = "root = /x\n"
        XCTAssertEqual(AD.contentByStrippingInjectedSuffix(inject(original)), original)
    }
}
