import XCTest
@testable import unison_ui_mac

/// PR2 writer core: block serialization and parsing, edit transforms, the
/// editable-file bound, ownership records, the bundle precondition, and the
/// syscall write/create/remove procedures. Pure logic is tested directly; the
/// serialization is also measured against real zsh and bash.
final class CommandLineSetupWriterCoreTests: XCTestCase {

    // MARK: Block: representability and serialization

    func test_representability_rejectsColonAndNewline() {
        XCTAssertTrue(CommandLineSetupBlock.isRepresentable(directory: "/Applications/unison-ui-mac.app/Contents/SharedSupport/bin"))
        XCTAssertFalse(CommandLineSetupBlock.isRepresentable(directory: "/a:b/bin"))
        XCTAssertFalse(CommandLineSetupBlock.isRepresentable(directory: "/a\nb/bin"))
        XCTAssertNil(CommandLineSetupBlock.blockText(directory: "/a:b/bin"))
        XCTAssertNil(CommandLineSetupBlock.fishFileText(directory: "/a\nb/bin"))
    }

    func test_posixSingleQuoted_roundTripsThroughDecode() {
        for s in ["/plain/bin", "/has space/bin", "/has'quote/bin", "/a$USER`x`$(id);/bin", "/tab\tinside/bin"] {
            let quoted = CommandLineSetupBlock.posixSingleQuoted(s)
            XCTAssertEqual(CommandLineSetupBlock.decodePosixSingleQuoted(quoted), s, "posix round trip for \(s)")
        }
    }

    func test_fishSingleQuoted_roundTripsThroughDecode() {
        for s in ["/plain/bin", "/has space/bin", "/has'quote/bin", "/back\\slash/bin"] {
            let quoted = CommandLineSetupBlock.fishSingleQuoted(s)
            XCTAssertEqual(CommandLineSetupBlock.decodeFishSingleQuoted(quoted), s, "fish round trip for \(s)")
        }
    }

    func test_blockText_templateDirectory_roundTrip() {
        let dir = "/Applications/unison-ui-mac.app/Contents/SharedSupport/bin"
        let block = CommandLineSetupBlock.blockText(directory: dir)!
        XCTAssertEqual(CommandLineSetupBlock.templateDirectory(ofBlockText: block), dir)
    }

    func test_fishFileText_templateDirectory_roundTrip_withAndWithoutTrailingNewline() {
        let dir = "/opt/x/Contents/SharedSupport/bin"
        let file = CommandLineSetupBlock.fishFileText(directory: dir)!
        XCTAssertEqual(CommandLineSetupBlock.fishTemplateDirectory(ofFileContents: file), dir)
        XCTAssertEqual(CommandLineSetupBlock.fishTemplateDirectory(ofFileContents: String(file.dropLast())), dir)
    }

    func test_templateDirectory_rejectsEditedBlock() {
        let dir = "/x/bin"
        var block = CommandLineSetupBlock.blockText(directory: dir)!
        block = block.replacingOccurrences(of: "export PATH", with: "export  PATH")  // edited
        XCTAssertNil(CommandLineSetupBlock.templateDirectory(ofBlockText: block))
    }

    func test_hash_isDeterministicAndSensitive() {
        let a = CommandLineSetupBlock.blockText(directory: "/a/bin")!
        let b = CommandLineSetupBlock.blockText(directory: "/b/bin")!
        XCTAssertEqual(CommandLineSetupBlock.hash(ofBlockText: a), CommandLineSetupBlock.hash(ofBlockText: a))
        XCTAssertNotEqual(CommandLineSetupBlock.hash(ofBlockText: a), CommandLineSetupBlock.hash(ofBlockText: b))
    }

    // MARK: Marker grammar

    func test_markerArrangement_none_single_malformed() {
        XCTAssertEqual(CommandLineSetupBlock.markerArrangement(inContents: "export PATH=/x\n"), .none)

        let block = CommandLineSetupBlock.blockText(directory: "/x/bin")!
        let file = "before\n\(block)\nafter\n"
        if case .single(let b, let e) = CommandLineSetupBlock.markerArrangement(inContents: file) {
            XCTAssertEqual(CommandLineSetupBlock.blockText(inContents: file, beginLine: b, endLine: e), block)
        } else { XCTFail("expected single") }

        // Lone begin marker.
        if case .malformed = CommandLineSetupBlock.markerArrangement(inContents: CommandLineSetupBlock.beginMarker + "\n") {} else { XCTFail("lone begin should be malformed") }
        // Reversed order.
        let reversed = CommandLineSetupBlock.endMarker + "\n" + CommandLineSetupBlock.beginMarker + "\n"
        if case .malformed = CommandLineSetupBlock.markerArrangement(inContents: reversed) {} else { XCTFail("reversed should be malformed") }
        // Duplicate begin.
        let dup = CommandLineSetupBlock.beginMarker + "\n" + CommandLineSetupBlock.beginMarker + "\n" + CommandLineSetupBlock.endMarker + "\n"
        if case .malformed = CommandLineSetupBlock.markerArrangement(inContents: dup) {} else { XCTFail("duplicate should be malformed") }
    }

    // MARK: Heredoc rule

    func test_heredoc_detection() {
        XCTAssertFalse(CommandLineSetupBound.containsHeredocOutsideMarkers(contents: "export PATH=/x\nalias l='ls'\n"))
        // The end marker's own << is exempt.
        let block = CommandLineSetupBlock.blockText(directory: "/x/bin")!
        XCTAssertFalse(CommandLineSetupBound.containsHeredocOutsideMarkers(contents: block))
        XCTAssertTrue(CommandLineSetupBound.containsHeredocOutsideMarkers(contents: "cat <<ONE <<TWO\n"))
        XCTAssertTrue(CommandLineSetupBound.containsHeredocOutsideMarkers(contents: "x=$(cat <<<'hi')\n"))  // here-string
        XCTAssertTrue(CommandLineSetupBound.containsHeredocOutsideMarkers(contents: "# a comment with << in it\n"))
    }

    // MARK: Bound evaluation

    private func ownershipAlways(_ owned: Bool) -> (String) -> Bool { { _ in owned } }

    func test_bound_appendable_whenNoBlock() {
        let r = CommandLineSetupBound.evaluateExistingFile(
            contents: "export PATH=/x\n", wholeFileParses: true, prefixParses: true,
            metadataOK: true, ownershipMatches: ownershipAlways(false))
        XCTAssertEqual(r, .appendable)
    }

    func test_bound_rewritable_whenOwnedBlock() {
        let dir = "/x/bin"
        let block = CommandLineSetupBlock.blockText(directory: dir)!
        let file = "head\n\(block)\ntail\n"
        let r = CommandLineSetupBound.evaluateExistingFile(
            contents: file, wholeFileParses: true, prefixParses: true,
            metadataOK: true, ownershipMatches: ownershipAlways(true))
        if case .rewritable(_, _, let d) = r { XCTAssertEqual(d, dir) } else { XCTFail("expected rewritable, got \(r)") }
    }

    func test_bound_foreign_whenUnowned() {
        let block = CommandLineSetupBlock.blockText(directory: "/x/bin")!
        let r = CommandLineSetupBound.evaluateExistingFile(
            contents: block, wholeFileParses: true, prefixParses: true,
            metadataOK: true, ownershipMatches: ownershipAlways(false))
        if case .foreignBlock = r {} else { XCTFail("expected foreignBlock, got \(r)") }
    }

    func test_bound_manualSetup_reasons() {
        // Metadata failure.
        var r = CommandLineSetupBound.evaluateExistingFile(
            contents: "x\n", wholeFileParses: true, prefixParses: true,
            metadataOK: false, ownershipMatches: ownershipAlways(false))
        if case .manualSetup = r {} else { XCTFail("metadata") }
        // Heredoc.
        r = CommandLineSetupBound.evaluateExistingFile(
            contents: "cat <<EOF\nx\nEOF\n", wholeFileParses: true, prefixParses: true,
            metadataOK: true, ownershipMatches: ownershipAlways(false))
        if case .manualSetup = r {} else { XCTFail("heredoc") }
        // Whole-file parse failure.
        r = CommandLineSetupBound.evaluateExistingFile(
            contents: "if then\n", wholeFileParses: false, prefixParses: true,
            metadataOK: true, ownershipMatches: ownershipAlways(false))
        if case .manualSetup = r {} else { XCTFail("parse") }
        // Prefix parse failure with an owned block present.
        let block = CommandLineSetupBlock.blockText(directory: "/x/bin")!
        r = CommandLineSetupBound.evaluateExistingFile(
            contents: "head\n\(block)\n", wholeFileParses: true, prefixParses: false,
            metadataOK: true, ownershipMatches: ownershipAlways(true))
        if case .manualSetup = r {} else { XCTFail("prefix parse") }
    }

    // MARK: Edit transforms

    func test_appended() {
        let block = "BLOCK"
        XCTAssertEqual(CommandLineSetupEdit.appended(to: "", blockText: block), "BLOCK\n")
        XCTAssertEqual(CommandLineSetupEdit.appended(to: "a\n", blockText: block), "a\nBLOCK\n")
        XCTAssertEqual(CommandLineSetupEdit.appended(to: "a", blockText: block), "a\nBLOCK\n")
    }

    func test_removed_roundTrip_and_outsideByteIdentical() {
        let block = CommandLineSetupBlock.blockText(directory: "/x/bin")!
        // Middle of file.
        let mid = "a\n\(block)\nb\n"
        let arr = CommandLineSetupBlock.markerArrangement(inContents: mid)
        guard case .single(let b, let e) = arr else { return XCTFail() }
        XCTAssertEqual(CommandLineSetupEdit.removed(mid, beginLine: b, endLine: e), "a\nb\n")

        // Appended to a file with no final newline, then removed: one trailing newline.
        let appended = CommandLineSetupEdit.appended(to: "a", blockText: block)  // "a\nBLOCK\n"
        guard case .single(let b2, let e2) = CommandLineSetupBlock.markerArrangement(inContents: appended) else { return XCTFail() }
        XCTAssertEqual(CommandLineSetupEdit.removed(appended, beginLine: b2, endLine: e2), "a\n")

        // Block at end with no final newline: text before it is byte-identical.
        let atEnd = "a\n" + block
        guard case .single(let b3, let e3) = CommandLineSetupBlock.markerArrangement(inContents: atEnd) else { return XCTFail() }
        XCTAssertEqual(CommandLineSetupEdit.removed(atEnd, beginLine: b3, endLine: e3), "a\n")
    }

    func test_rewritten_outsideByteIdentical() {
        let old = CommandLineSetupBlock.blockText(directory: "/old/bin")!
        let new = CommandLineSetupBlock.blockText(directory: "/new/bin")!
        let file = "x\n\(old)\ny\n"
        guard case .single(let b, let e) = CommandLineSetupBlock.markerArrangement(inContents: file) else { return XCTFail() }
        let out = CommandLineSetupEdit.rewritten(file, beginLine: b, endLine: e, newBlockText: new)
        XCTAssertEqual(out, "x\n\(new)\ny\n")
    }

    // MARK: Ownership record

    private func freshDefaults() -> UserDefaults {
        let name = "clsetup-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        return d
    }

    func test_record_writePending_promote_delete_isOwned() {
        let d = freshDefaults()
        let rec = CommandLineSetupOwnership(path: "/f", hash: "abc", bundlePath: "/b", date: Date())
        XCTAssertTrue(CommandLineSetupRecordStore.writePending(rec, defaults: d))
        XCTAssertEqual(CommandLineSetupRecordStore.pending(defaults: d), rec)
        XCTAssertTrue(CommandLineSetupRecordStore.isOwned(path: "/f", blockHash: "abc", defaults: d))
        XCTAssertFalse(CommandLineSetupRecordStore.isOwned(path: "/f", blockHash: "xyz", defaults: d))
        CommandLineSetupRecordStore.promote(defaults: d)
        XCTAssertNil(CommandLineSetupRecordStore.pending(defaults: d))
        XCTAssertEqual(CommandLineSetupRecordStore.confirmed(defaults: d), rec)
        XCTAssertTrue(CommandLineSetupRecordStore.isOwned(path: "/f", blockHash: "abc", defaults: d))
        CommandLineSetupRecordStore.deleteBoth(defaults: d)
        XCTAssertNil(CommandLineSetupRecordStore.confirmed(defaults: d))
        XCTAssertFalse(CommandLineSetupRecordStore.isOwned(path: "/f", blockHash: "abc", defaults: d))
    }

    func test_classify_mutation() {
        XCTAssertEqual(CommandLineSetupRecordStore.classify(renameSucceeded: true, errnoValue: 0), .mutated)
        XCTAssertEqual(CommandLineSetupRecordStore.classify(renameSucceeded: false, errnoValue: EACCES), .notMutated)
        XCTAssertEqual(CommandLineSetupRecordStore.classify(renameSucceeded: false, errnoValue: ENOENT), .notMutated)
        XCTAssertEqual(CommandLineSetupRecordStore.classify(renameSucceeded: false, errnoValue: EIO), .uncertain)
    }

    // MARK: Bundle precondition

    func test_bundlePrecondition() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clbundle-\(UUID().uuidString)")
        let app = root.appendingPathComponent("unison-ui-mac.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        let bin = app.appendingPathComponent("Contents/SharedSupport/bin")
        try? FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cltool = macos.appendingPathComponent("cltool")
        FileManager.default.createFile(atPath: cltool.path, contents: Data("x".utf8),
                                       attributes: [.posixPermissions: 0o755])
        try? FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("unison").path,
                                                    withDestinationPath: "../../MacOS/cltool")
        defer { try? FileManager.default.removeItem(at: root) }

        let fs = RealCommandLineToolFileSystem()
        XCTAssertTrue(CommandLineSetupBundle.preconditionSatisfied(bundleURL: app, fs: fs))

        // Retarget the symlink: precondition fails.
        try? FileManager.default.removeItem(atPath: bin.appendingPathComponent("unison").path)
        try? FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("unison").path,
                                                    withDestinationPath: "../../MacOS/other")
        XCTAssertFalse(CommandLineSetupBundle.preconditionSatisfied(bundleURL: app, fs: fs))
    }

    // MARK: Writer syscalls (temp dir)

    private func makeTempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clwriter-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func test_writer_replace_happyPath_preservesModeAndContent() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".zprofile")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let snap = CommandLineSetupWriter.snapshot(atPath: file.path)!
        let newContents = "original\nnew line\n"
        let outcome = CommandLineSetupWriter.replace(resolvedPath: file.path, newContents: newContents, expected: snap)
        XCTAssertEqual(outcome, .mutated)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), newContents)
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600, "metadata (mode) preserved")
    }

    func test_writer_replace_refusesOnSeamChange() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".zprofile")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        let snap = CommandLineSetupWriter.snapshot(atPath: file.path)!
        // Change the file after the snapshot.
        try "changed by another writer\n".write(to: file, atomically: true, encoding: .utf8)
        let outcome = CommandLineSetupWriter.replace(resolvedPath: file.path, newContents: "x\n", expected: snap)
        if case .notMutated = outcome {} else { XCTFail("expected notMutated, got \(outcome)") }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed by another writer\n")
    }

    func test_writer_create_happyPath_andRefusesWhenOccupied() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".zprofile")
        let outcome = CommandLineSetupWriter.create(resolvedPath: file.path, contents: "block\n",
                                                    ensuringParentDirectory: false)
        XCTAssertEqual(outcome, .mutated)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "block\n")

        // A second create must refuse (RENAME_EXCL / name now occupied).
        let again = CommandLineSetupWriter.create(resolvedPath: file.path, contents: "other\n",
                                                  ensuringParentDirectory: false)
        if case .notMutated = again {} else { XCTFail("expected notMutated, got \(again)") }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "block\n")
    }

    func test_writer_create_makesFishConfdParent() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("fish/conf.d/unison-ui-mac.fish")
        let outcome = CommandLineSetupWriter.create(resolvedPath: file.path, contents: "fish\n",
                                                    ensuringParentDirectory: true)
        XCTAssertEqual(outcome, .mutated)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "fish\n")
    }

    func test_writer_removeFile() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("unison-ui-mac.fish")
        try "fish\n".write(to: file, atomically: true, encoding: .utf8)
        let snap = CommandLineSetupWriter.snapshot(atPath: file.path)!
        XCTAssertEqual(CommandLineSetupWriter.removeFile(resolvedPath: file.path, expected: snap), .mutated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // Regression (P1): fish removal must re-check identity and refuse to delete a
    // file whose contents changed since it was inspected.
    func test_writer_removeFile_refusesWhenContentChangedSinceSnapshot() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("unison-ui-mac.fish")
        try "app fish config\n".write(to: file, atomically: true, encoding: .utf8)
        let snap = CommandLineSetupWriter.snapshot(atPath: file.path)!
        // Another editor replaces the file's contents after inspection.
        try "user's own configuration\n".write(to: file, atomically: true, encoding: .utf8)
        let outcome = CommandLineSetupWriter.removeFile(resolvedPath: file.path, expected: snap)
        if case .notMutated = outcome {} else { XCTFail("expected notMutated, got \(outcome)") }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "user's own configuration\n",
                       "the changed file is not deleted")
    }

    // Regression (P2): replacement must detect a symlink introduced at the name
    // since the snapshot, even one that resolves to the same bytes, and refuse
    // rather than replace it (which would disconnect a dotfile-managed file).
    func test_writer_replace_refusesWhenNameBecomesSymlinkToSameBytes() throws {
        let dir = makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".zprofile")
        try "export FOO=1\n".write(to: file, atomically: true, encoding: .utf8)
        let snap = CommandLineSetupWriter.snapshot(atPath: file.path)!
        // A dotfile manager moves the file into a repo (same inode, same bytes) and
        // substitutes a symlink at the original name pointing at the moved file.
        let repo = dir.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let moved = repo.appendingPathComponent(".zprofile")
        try FileManager.default.moveItem(at: file, to: moved)
        try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: moved.path)

        let outcome = CommandLineSetupWriter.replace(resolvedPath: file.path, newContents: "changed\n", expected: snap)
        if case .notMutated = outcome {} else { XCTFail("expected notMutated, got \(outcome)") }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file.path), moved.path,
                       "the symlink is preserved")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "export FOO=1\n", "the repo file is untouched")
    }

    // MARK: Serialization measured against real shells

    func test_serialization_measured_zshAndBash_noSubstitution() throws {
        // A directory holding characters that would expand or execute if the
        // serialization were wrong. No colon (unrepresentable) and no newline.
        let hostile = "/tmp/cl setup $USER `id` $(id) 'q' ;x/bin"
        let block = CommandLineSetupBlock.blockText(directory: hostile)!
        for shell in ["/bin/zsh", "/bin/bash"] {
            guard FileManager.default.isExecutableFile(atPath: shell) else { continue }
            let script = block + "\nprintf '%s' \"${PATH%%:*}\"\n"
            let first = try runShell(shell, script: script)
            XCTAssertEqual(first, hostile, "\(shell): the literal directory is first on PATH, unexpanded")
        }
    }

    private func runShell(_ shell: String, script: String) throws -> String {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clshell-\(UUID().uuidString)")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = [tmp.path]
        p.environment = ["PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
