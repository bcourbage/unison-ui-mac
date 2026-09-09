import Foundation

// The in-bundle command the PATH entry points at, and the precondition the app
// checks before it writes one. See docs/command-line-setup-design.md, "The
// command inside the bundle".
//
// The bundle ships Contents/SharedSupport/bin/unison as a symlink to
// ../../MacOS/cltool (added by the app target's post-build phase). The PATH entry
// puts Contents/SharedSupport/bin on PATH, so `unison` in a login shell resolves
// to this app's launcher without a system directory or elevation.

enum CommandLineSetupBundle {

    /// The directory the PATH entry adds: `<bundle>/Contents/SharedSupport/bin`.
    /// Computed from the bundle path at every call, never remembered, so a moved
    /// app produces a new directory and the entry follows it.
    static func binDirectory(bundleURL: URL) -> String {
        bundleURL.appendingPathComponent("Contents/SharedSupport/bin").path
    }

    /// The in-bundle command itself: `<bundle>/Contents/SharedSupport/bin/unison`.
    /// Copy This App's Command Path copies this string for a peer's servercmd.
    static func commandPath(bundleURL: URL) -> String {
        bundleURL.appendingPathComponent("Contents/SharedSupport/bin/unison").path
    }

    /// The launcher the command must resolve to: `<bundle>/Contents/MacOS/cltool`.
    static func launcherPath(bundleURL: URL) -> String {
        bundleURL.appendingPathComponent("Contents/MacOS/cltool").path
    }

    /// Whether the bundle carries a usable command: `Contents/SharedSupport/bin/
    /// unison` is a symlink whose resolved path is this bundle's `Contents/MacOS/
    /// cltool`, and that target is a regular executable file. Add Terminal Setup,
    /// Use This Copy and a startup rewrite require this; Remove does not. Failure
    /// means a damaged bundle, reported as "This app's command is missing from the
    /// bundle. Reinstall the app."
    static func preconditionSatisfied(bundleURL: URL, fs: CommandLineToolFileSystem) -> Bool {
        let command = commandPath(bundleURL: bundleURL)
        guard fs.isSymlink(atPath: command),
              let commandReal = fs.realPath(ofPath: command),
              let launcherReal = fs.realPath(ofPath: launcherPath(bundleURL: bundleURL)),
              commandReal == launcherReal,
              fs.isExecutableFile(atPath: commandReal)
        else { return false }
        return true
    }

    static let missingCommandNote = "This app's command is missing from the bundle. Reinstall the app."
}
