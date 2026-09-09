import XCTest
@testable import unison_ui_mac

/// The shared command-line-setup helpers that remain after the v0.7.0 privileged
/// launcher was removed: the marker-bracketed parsing and the filesystem
/// abstraction. The setup logic itself is covered by the CommandLineSetup* tests.
final class CommandLineToolStatusTests: XCTestCase {

    func test_extractMarkedPath_returnsTextBetweenMarkers() {
        let s = CommandLineToolStatus.pathMarkerStart
        let e = CommandLineToolStatus.pathMarkerEnd
        XCTAssertEqual(CommandLineToolStatus.extractMarkedPath(from: "banner\n\(s)/usr/bin\(e)trailer"), "/usr/bin")
        XCTAssertEqual(CommandLineToolStatus.extractMarkedPath(from: "\(s)\(e)"), "")
    }

    func test_extractMarkedPath_nilWhenMarkersAbsentOrReversed() {
        let s = CommandLineToolStatus.pathMarkerStart
        let e = CommandLineToolStatus.pathMarkerEnd
        XCTAssertNil(CommandLineToolStatus.extractMarkedPath(from: "no markers here"))
        XCTAssertNil(CommandLineToolStatus.extractMarkedPath(from: "\(e)/usr/bin\(s)"))
    }

    func test_realFileSystem_basicQueries() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cltfs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("l")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "f")

        let fs = RealCommandLineToolFileSystem()
        XCTAssertTrue(fs.entryExists(atPath: file.path))
        XCTAssertFalse(fs.isSymlink(atPath: file.path))
        XCTAssertTrue(fs.isSymlink(atPath: link.path))
        XCTAssertEqual(fs.linkTarget(atPath: link.path), "f")
        XCTAssertEqual(fs.realPath(ofPath: link.path), fs.realPath(ofPath: file.path))
        XCTAssertTrue(fs.isDirectory(atPath: dir.path))
        XCTAssertEqual(fs.contentsOfFile(atPath: file.path), "hello\n")
    }
}
