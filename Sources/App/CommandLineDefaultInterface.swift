import Foundation

/// The interface `unison` uses when the caller does not pass `-ui`. An explicit
/// `-ui graphic` or `-ui text` always overrides this, because it is injected in
/// front of the caller's tokens and upstream keeps the last `-ui` given; this
/// only fills in the omitted default.
///
/// When no preference has been saved, the default is graphical, so typing
/// `unison <profile>` opens this app. A saved Graphical or Text choice is kept.
/// There is no per-account migration: every account without a saved preference
/// gets the graphical default, which is a behavior change for existing launcher
/// users who relied on a bare `unison <profile>` running the text interface.
///
/// Scripts should pass `-ui text` explicitly rather than depend on this default:
/// with the graphical default in effect, a headless `unison <profile>` (over ssh
/// or from cron, with no window server) reports the no-session error instead of
/// running the text interface.
enum CommandLineDefaultInterface: String {
    case graphic
    case text

    static let key = "commandLine.defaultInterface"

    /// Resolve the effective default and persist it, so the stored value matches
    /// what a bare `unison` used. `AppDelegate` calls this once on launch (except
    /// under the test host and the launch smoke; see `shouldResolveOnLaunch`).
    @discardableResult
    static func resolved(defaults: UserDefaults = .standard) -> CommandLineDefaultInterface {
        let value = current(defaults: defaults)
        defaults.set(value.rawValue, forKey: key)
        return value
    }

    /// The effective default without persisting: a saved Graphical or Text
    /// choice, or graphical when nothing is saved. Used for the Settings display,
    /// so opening Settings does not write anything.
    static func current(defaults: UserDefaults = .standard) -> CommandLineDefaultInterface {
        if let raw = defaults.string(forKey: key), let value = CommandLineDefaultInterface(rawValue: raw) {
            return value
        }
        return .graphic
    }

    static func set(_ value: CommandLineDefaultInterface, defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: key)
    }

    /// Whether launch should resolve-and-persist the default. The XCTest host and
    /// the macOS-baseline launch smoke both run `applicationDidFinishLaunching` in
    /// a throwaway process; neither reads this preference, and neither may write
    /// the real preference domain, so both are excluded (matching the other
    /// launch-time guards).
    static func shouldResolveOnLaunch(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
            && environment["UNISON_UI_SMOKE"] == nil
    }

    /// The value to inject after `-ui`. Unison names the interfaces `graphic` and
    /// `text`, which are exactly the raw values here.
    var uiArgument: String { rawValue }

    static let label = "Default interface for the unison command"
    static let explanation = "Used when a command omits -ui. An explicit -ui graphic or -ui text always wins."
}
