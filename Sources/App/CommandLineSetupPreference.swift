import Foundation

// The one preference for command-line setup: keep unison in Terminal pointing at
// this app. See docs/command-line-setup-design.md, "Preference".
//
// On: the app offers setup at launch when unison does not resolve to it, and
// maintains an owned block. Off: the app neither offers nor writes. The initial
// value for an account that has never run a version with this preference is on,
// migrated from 0.7.0's `commandLineTool.doNotAsk` (true → off), after which the
// old key is removed.

enum CommandLineSetupPreference {

    static let keepKey = "commandLine.keepInTerminal"
    static let legacyDoNotAskKey = "commandLineTool.doNotAsk"

    /// Whether the preference is on. On first read for an account that has never
    /// stored it, migrate from 0.7.0: on unless `commandLineTool.doNotAsk` was
    /// true, then remove the old key. The migration is one-time and idempotent.
    static func keepInTerminal(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: keepKey) != nil {
            return defaults.bool(forKey: keepKey)
        }
        let value = !defaults.bool(forKey: legacyDoNotAskKey)
        defaults.set(value, forKey: keepKey)
        defaults.removeObject(forKey: legacyDoNotAskKey)
        return value
    }

    static func setKeepInTerminal(_ on: Bool, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: keepKey)
        defaults.removeObject(forKey: legacyDoNotAskKey)
    }

    static let checkboxTitle = "Keep unison in Terminal pointing at this app"
    static let checkboxExplanation = "Offers setup at launch when it is missing, and repairs it if the app moves."
}
