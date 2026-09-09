import Foundation

// Shared helpers for command-line setup: the filesystem abstraction the setup
// logic is tested against, this app's identifier, and the marker-bracketed
// parsing of a login shell's output.
//
// v0.7.0 shipped a privileged command-line launcher here (an admin `do shell
// script` that created /usr/local/bin/unison, with classification, an action
// policy, a first-launch prompt and a two-context status). That mechanism is
// replaced by the unprivileged in-bundle command plus a PATH entry in the user's
// own files (see docs/command-line-setup-design.md and the CommandLineSetup*
// types); the elevation code and its release gate are gone. Only these shared
// pieces, which the new code reuses, remain.

// MARK: - Filesystem abstraction

/// The few filesystem questions the setup logic asks, behind a protocol so it can
/// be tested against fixture directories and against fakes.
protocol CommandLineToolFileSystem {
    /// True for a regular file, directory, or symlink (dangling included).
    func entryExists(atPath path: String) -> Bool
    /// True if the entry is a symlink (whether or not its target exists).
    func isSymlink(atPath path: String) -> Bool
    /// The link's target as stored (relative or absolute); nil for a non-link.
    func linkTarget(atPath path: String) -> String?
    /// The canonical path with every symlink resolved; nil when any component
    /// does not exist (a dangling link).
    func realPath(ofPath path: String) -> String?
    func isExecutableFile(atPath path: String) -> Bool
    /// `CFBundleIdentifier` of the bundle at `bundlePath`, nil if unreadable.
    func bundleIdentifier(ofBundleAtPath bundlePath: String) -> String?
    func isDirectory(atPath path: String) -> Bool
    func contentsOfDirectory(atPath path: String) -> [String]
    func contentsOfFile(atPath path: String) -> String?
}

struct RealCommandLineToolFileSystem: CommandLineToolFileSystem {
    private let fm = FileManager.default

    func entryExists(atPath path: String) -> Bool {
        (try? fm.attributesOfItem(atPath: path)) != nil
    }
    func isSymlink(atPath path: String) -> Bool {
        (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }
    func linkTarget(atPath path: String) -> String? {
        try? fm.destinationOfSymbolicLink(atPath: path)
    }
    func realPath(ofPath path: String) -> String? {
        guard let cstr = realpath(path, nil) else { return nil }
        defer { free(cstr) }
        return String(cString: cstr)
    }
    func isExecutableFile(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue && fm.isExecutableFile(atPath: path)
    }
    func bundleIdentifier(ofBundleAtPath bundlePath: String) -> String? {
        Bundle(path: bundlePath)?.bundleIdentifier
    }
    func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
    func contentsOfDirectory(atPath path: String) -> [String] {
        (try? fm.contentsOfDirectory(atPath: path)) ?? []
    }
    func contentsOfFile(atPath path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}

// MARK: - Shared constants and parsing

enum CommandLineToolStatus {

    static let ourBundleIdentifier = "net.courbage.unison-ui-mac"

    /// Markers a probe brackets its answer with, so a banner printed by a login
    /// startup file before the answer is not mistaken for it.
    static let pathMarkerStart = "@@UNISON_UI_MAC_PATH_START@@"
    static let pathMarkerEnd = "@@UNISON_UI_MAC_PATH_END@@"

    /// The text between the two markers, or nil when the markers are absent or out
    /// of order.
    static func extractMarkedPath(from output: String) -> String? {
        guard let start = output.range(of: pathMarkerStart),
              let end = output.range(of: pathMarkerEnd, range: start.upperBound..<output.endIndex)
        else { return nil }
        return String(output[start.upperBound..<end.lowerBound])
    }
}
