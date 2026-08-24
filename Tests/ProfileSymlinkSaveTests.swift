import XCTest
@testable import unison_ui_mac

/// SF15: saving a profile whose `.prf` is a SYMLINK (a common dotfiles-repo setup)
/// must write THROUGH the link to its target, preserving the symlink — not replace
/// the symlink with a regular file and orphan the linked copy. Exercises the real
/// `SystemFileOps.writeAtomic` against a real temporary filesystem.
final class ProfileSymlinkSaveTests: XCTestCase {

    private func tempDir() throws -> String {
        let d = (NSTemporaryDirectory() as NSString).appendingPathComponent("symsave-" + UUID().uuidString)
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    func test_writeAtomic_throughSymlink_preservesLink_updatesTarget() throws {
        let fm = FileManager.default
        let dir = try tempDir()
        defer { try? fm.removeItem(atPath: dir) }

        // A real target file in a "dotfiles" subdir, and a symlink standing in for
        // ~/.unison/foo.prf → dotfiles/foo.prf.
        let dotfiles = (dir as NSString).appendingPathComponent("dotfiles")
        try fm.createDirectory(atPath: dotfiles, withIntermediateDirectories: true)
        let target = (dotfiles as NSString).appendingPathComponent("foo.prf")
        try "root = /old\n".write(toFile: target, atomically: true, encoding: .utf8)
        let link = (dir as NSString).appendingPathComponent("foo.prf")
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)

        try SystemFileOps().writeAtomic("root = /new\n", to: link)

        // The link is still a symlink pointing at the same target...
        let attrs = try fm.attributesOfItem(atPath: link)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                       "the profile symlink must be preserved, not replaced by a regular file")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link), target)
        // ...and the TARGET holds the new content (write-through).
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "root = /new\n")
    }

    func test_writeAtomic_plainFile_unchangedBehavior() throws {
        let fm = FileManager.default
        let dir = try tempDir()
        defer { try? fm.removeItem(atPath: dir) }
        let path = (dir as NSString).appendingPathComponent("bar.prf")
        try "a\n".write(toFile: path, atomically: true, encoding: .utf8)

        try SystemFileOps().writeAtomic("b\n", to: path)

        let attrs = try fm.attributesOfItem(atPath: path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "b\n")
    }

    func test_copy_throughSymlink_backsUpContentNotLink() throws {
        let fm = FileManager.default
        let dir = try tempDir()
        defer { try? fm.removeItem(atPath: dir) }
        let target = (dir as NSString).appendingPathComponent("real.prf")
        try "content\n".write(toFile: target, atomically: true, encoding: .utf8)
        let link = (dir as NSString).appendingPathComponent("link.prf")
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        let bak = (dir as NSString).appendingPathComponent("link.prf.bak")

        try SystemFileOps().copy(from: link, to: bak)

        // The backup is a real regular file holding the pre-save bytes, not a
        // symlink that would track the target.
        let attrs = try fm.attributesOfItem(atPath: bak)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try String(contentsOfFile: bak, encoding: .utf8), "content\n")
    }
}
