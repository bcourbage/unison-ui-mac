import Foundation

/// The interface `unison` uses when the caller does not pass `-ui`. An explicit
/// `-ui graphic` or `-ui text` always overrides this, because it is injected in
/// front of the caller's tokens and upstream keeps the last `-ui` given; this
/// only fills in the omitted default.
///
/// A new account defaults to graphical, so typing `unison <profile>` opens this
/// app. An account that already carried a command-line preference ran a version
/// (0.7.0 or 0.8.0) whose omitted default was text, so it keeps text and existing
/// habits and scripts are unchanged. The choice is resolved once, from that
/// signal, and then persisted so later preference writes cannot change it.
///
/// Scripts should pass `-ui text` explicitly rather than depend on this default:
/// with the graphical default in effect, a headless `unison <profile>` (over ssh
/// or from cron, with no window server) reports the no-session error instead of
/// running the text interface.
enum CommandLineDefaultInterface: String {
    case graphic
    case text

    static let key = "commandLine.defaultInterface"

    /// Resolve the effective default, migrating on first read and persisting the
    /// result so the decision is stable. `AppDelegate` resolves it early, before
    /// any other command-line preference is written, so a fresh account is not
    /// mistaken for an upgrade.
    @discardableResult
    static func resolved(defaults: UserDefaults = .standard) -> CommandLineDefaultInterface {
        let value = current(defaults: defaults)
        defaults.set(value.rawValue, forKey: key)
        return value
    }

    /// The effective default without persisting. `resolved()` locks the decision
    /// by writing it; `current()` is for reading it back afterwards (the Settings
    /// display), so opening Settings does not itself migrate an account.
    static func current(defaults: UserDefaults = .standard) -> CommandLineDefaultInterface {
        if let raw = defaults.string(forKey: key), let value = CommandLineDefaultInterface(rawValue: raw) {
            return value
        }
        return wasUpgraded(defaults: defaults) ? .text : .graphic
    }

    /// True when the account already carried a command-line preference from a
    /// prior version. Both keys are written by 0.7.0/0.8.0 before this feature
    /// existed; a fresh account has neither at the point this is first resolved.
    static func wasUpgraded(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: CommandLineSetupPreference.keepKey) != nil
            || defaults.object(forKey: CommandLineSetupPreference.legacyDoNotAskKey) != nil
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
