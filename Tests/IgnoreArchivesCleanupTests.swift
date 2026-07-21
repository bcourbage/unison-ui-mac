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

    // MARK: - External-edit-safe restoration (PR: reread-at-restore)

    // The restore path re-reads the CURRENT file and strips exactly the
    // app-owned trailing suffix, never writing back a saved snapshot. The pure
    // decision `ignoreArchivesRestoreAction(currentContent:)` and the seam
    // `performIgnoreArchivesRestore(read:write:)` capture that behavior.

    func test_restoreAction_ordinaryInjected_writesStrippedOriginal() {
        let original = "root = /a\nroot = /b\n"
        XCTAssertEqual(AD.ignoreArchivesRestoreAction(currentContent: inject(original)),
                       .write(original))
    }

    func test_restoreAction_externalEditBeforeSuffix_preservesEditedPrefix() {
        // User edited the profile WHILE recovery was active: the prefix differs
        // from what we injected, but our suffix is still trailing. Restoration
        // must strip only the suffix and keep the EDITED prefix verbatim — never
        // clobber it with the pre-edit snapshot.
        let edited = "root = /a\nroot = /b\n# user added this mid-recovery\nlog = true\n"
        XCTAssertEqual(AD.ignoreArchivesRestoreAction(currentContent: inject(edited)),
                       .write(edited))
    }

    func test_restoreAction_suffixAlreadyRemovedExternally_noWrite() {
        let content = "root = /a\nroot = /b\n"   // no trailing app suffix
        XCTAssertEqual(AD.ignoreArchivesRestoreAction(currentContent: content), .noWriteAbsent)
    }

    func test_restoreAction_unexpectedModifiedContentWithoutSuffix_noWrite() {
        // Wholly replaced content that does not end with our suffix → we must
        // NOT write anything (and never a saved original).
        let content = "completely different\ncontent the user wrote\n"
        XCTAssertEqual(AD.ignoreArchivesRestoreAction(currentContent: content), .noWriteAbsent)
    }

    func test_restoreAction_readFailure_isUnreadableNoWrite() {
        XCTAssertEqual(AD.ignoreArchivesRestoreAction(currentContent: nil), .noWriteUnreadable)
    }

    // Seam: full read→decide→write behavior, incl. read/write failure, via closures.

    func test_perform_restore_success_writesStrippedAndReportsRestored() {
        let original = "root = /a\n"
        var written: String?
        let result = AD.performIgnoreArchivesRestore(
            read: { self.inject(original) },
            write: { written = $0 })
        XCTAssertEqual(result, .restored)
        XCTAssertEqual(written, original, "wrote exactly the stripped current content")
    }

    func test_perform_restore_suffixAbsent_nothingToDo_noWriteCall() {
        var wrote = false
        let result = AD.performIgnoreArchivesRestore(
            read: { "root = /a\n" },
            write: { _ in wrote = true })
        XCTAssertEqual(result, .nothingToDo)
        XCTAssertFalse(wrote, "no write is attempted when the suffix is absent")
    }

    func test_perform_restore_readFailure_preservesFile_notRestored() {
        var wrote = false
        let result = AD.performIgnoreArchivesRestore(
            read: { nil },
            write: { _ in wrote = true })
        XCTAssertEqual(result, .readFailed)
        XCTAssertFalse(wrote, "an unreadable file is never overwritten with a saved original")
    }

    func test_perform_restore_writeFailure_reportedAsFailed_notRestored() {
        struct WriteError: Error {}
        let result = AD.performIgnoreArchivesRestore(
            read: { self.inject("root = /a\n") },
            write: { _ in throw WriteError() })
        XCTAssertEqual(result, .writeFailed,
                       "a failed write leaves the suffix for launch cleanup and is NOT reported restored")
    }

    func test_perform_restore_repeated_secondPassIsNothingToDo() {
        // First pass strips and "persists" into a tiny in-memory file; a second
        // restore over the now-stripped content is a benign no-op.
        var file = inject("root = /a\n")
        let first = AD.performIgnoreArchivesRestore(read: { file }, write: { file = $0 })
        XCTAssertEqual(first, .restored)
        XCTAssertEqual(file, "root = /a\n")
        let second = AD.performIgnoreArchivesRestore(read: { file }, write: { file = $0 })
        XCTAssertEqual(second, .nothingToDo)
        XCTAssertEqual(file, "root = /a\n", "unchanged on the idempotent second pass")
    }

    func test_perform_restore_crlfAndNoTrailingNewline_preservedThroughSeam() {
        for original in ["root = /a\r\nroot = /b\r\n", "root = /a\nroot = /b", "only one line no newline"] {
            var file = inject(original)
            let r = AD.performIgnoreArchivesRestore(read: { file }, write: { file = $0 })
            XCTAssertEqual(r, .restored)
            XCTAssertEqual(file, original, "content shape preserved verbatim through restore")
        }
    }

    func test_perform_restore_neverRemovesUserAuthoredSimilarMarker() {
        // A user profile that merely CONTAINS the marker text (not as the trailing
        // app block) must be left byte-for-byte untouched by restore.
        let userContent = "# I referenced \(marker) in a note\nignorearchives = true\nroot = /a\n"
        var file = userContent
        var wrote = false
        let r = AD.performIgnoreArchivesRestore(read: { file }, write: { file = $0; wrote = true })
        XCTAssertEqual(r, .nothingToDo)
        XCTAssertFalse(wrote)
        XCTAssertEqual(file, userContent)
    }
}
