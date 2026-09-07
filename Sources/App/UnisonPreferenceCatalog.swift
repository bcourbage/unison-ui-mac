import Foundation

/// The preferences the vendored Unison engine accepts in a profile, with the
/// facts `Prefs.processLines` (`src/ubase/prefs.ml`) needs about each one:
/// whether the name is registered at all, whether it is command-line only,
/// whether it is a pseudo-preference (registered, but rejected in profiles as
/// if unknown), how its value is parsed, and whether it accumulates.
///
/// Derived from upstream `bcpierce00/unison` at commit
/// `91421d0617b0fb543c0eee51bcb4d4791d8b0631` (v2.54.0-19), the commit the
/// vendored blob and manual are built from (`vendor/README.md`):
///
/// - Every `Prefs.create*` and `Pred.create` registration in `src/`, with
///   the value kind given by the constructor (`createBool` → boolean,
///   `createInt` → integer, `createString` → string, `createStringList` and
///   `Pred.create` → list, `createBoolWithDefault` and custom `create` →
///   free-form).
/// - `~cli_only:true` registrations (rejected in a profile with
///   "is a command line-only option").
/// - `` `Internal `Pseudo `` registrations (raise `Not_found` in
///   `processLines`, so they are reported as "not a valid option").
/// - `Prefs.alias` and `Pred.alias` calls; an alias shares its target's kind
///   and command-line-only flag.
///
/// `scripts/check-pref-catalog.sh` compares this table with the names the
/// built engine prints for `unison -help`, so a vendored-blob bump that adds
/// or removes a preference fails CI until the table is updated.
enum UnisonPreferenceCatalog {

    /// How `processLines` converts the value text.
    enum ValueKind: Equatable {
        /// `Uarg.Bool`: exactly `true` or `false`, else fatal.
        case bool
        /// `Uarg.Int`: `int_of_string`, else fatal.
        case int
        /// `Uarg.String` with the last assignment winning.
        case string
        /// `Uarg.String` accumulating in order.
        case list
        /// `Uarg.String` with a preference-specific parser (`color`, `ui`,
        /// `repeat`, …); the catalog does not validate these values.
        case custom

        var accumulates: Bool { self == .list }
    }

    struct Entry: Equatable {
        /// The canonical registered name (an alias resolves to its target).
        let name: String
        let kind: ValueKind
        /// Registered with `~cli_only:true`.
        let commandLineOnly: Bool
        /// Registered under `` `Internal `Pseudo ``; a profile line naming it
        /// is rejected as "not a valid option".
        let pseudo: Bool
    }

    /// Look up a name as written in a profile. Returns nil for a name the
    /// engine does not register (Unison: "`x' is not a valid option").
    static func entry(for name: String) -> Entry? {
        if let alias = aliases[name] { return entry(for: alias) }
        guard let (kind, flags) = registrations[name] else { return nil }
        return Entry(name: name, kind: kind,
                     commandLineOnly: flags.contains(.commandLineOnly),
                     pseudo: flags.contains(.pseudo))
    }

    /// Every name a profile line may carry (registrations and aliases).
    static var allNames: Set<String> {
        Set(registrations.keys).union(aliases.keys)
    }

    // MARK: - Data

    private struct Flags: OptionSet {
        let rawValue: Int
        static let commandLineOnly = Flags(rawValue: 1)
        static let pseudo = Flags(rawValue: 2)
    }

    private static let none: Flags = []

    // Alias → canonical name. `Prefs.alias` in fileinfo.ml, props.ml,
    // main.ml, stasher.ml, update.ml, uicommon.ml, globals.ml, remote.ml;
    // `Pred.alias` in stasher.ml.
    private static let aliases: [String: String] = [
        "pretendwin": "ignoreinodenumbers",
        "numericIds": "numericids",
        "host": "listen",
        "backuplocation": "backuploc",
        "mirrorversions": "maxbackups",
        "backupversions": "maxbackups",
        "showArchiveName": "showarchive",
        "testServer": "testserver",
        "confirmbigdeletes": "confirmbigdel",
        "killServer": "killserver",
        "mirror": "backup",
        "mirrornot": "backupnot",
        "backupcurrent": "backupcurr",
        "backupcurrentnot": "backupcurrnot",
    ]

    private static let registrations: [String: (ValueKind, Flags)] = [
        // createBool
        "acl": (.bool, none),
        "addversionno": (.bool, none),
        "auto": (.bool, none),
        "backups": (.bool, none),
        "batch": (.bool, none),
        "confirmbigdel": (.bool, none),
        "confirmmerge": (.bool, none),
        "contactquietly": (.bool, none),
        "copyonconflict": (.bool, none),
        "debugtimes": (.bool, none),
        "dontchmod": (.bool, none),
        "dumbtty": (.bool, none),
        "expert": (.bool, none),
        "fastercheckUNSAFE": (.bool, none),
        "fat": (.bool, none),
        "group": (.bool, none),
        "halfduplex": (.bool, none),
        "ignorearchives": (.bool, none),
        "ignoreinodenumbers": (.bool, none),
        "ignorelocks": (.bool, none),
        "keeptempfilesaftermerge": (.bool, none),
        "killserver": (.bool, none),
        "log": (.bool, none),
        "moves-experimental": (.bool, none),
        "numericids": (.bool, none),
        "owner": (.bool, none),
        "rsync": (.bool, none),
        "showarchive": (.bool, none),
        "showprev": (.bool, none),
        "silent": (.bool, none),
        "sortbysize": (.bool, none),
        "sortnewfirst": (.bool, none),
        "stream": (.bool, none),
        "terse": (.bool, none),
        "timers": (.bool, none),
        "times": (.bool, none),
        "watch": (.bool, none),
        "xattrs": (.bool, none),
        "xferbycopying": (.bool, none),
        // createBool, command-line only
        "dumparchives": (.bool, .commandLineOnly),
        "i": (.bool, .commandLineOnly),
        "prefsdocs": (.bool, .commandLineOnly),
        "selftest": (.bool, .commandLineOnly),
        "server": (.bool, .commandLineOnly),
        "testserver": (.bool, .commandLineOnly),
        "version": (.bool, .commandLineOnly),
        // createBool, pseudo
        "allHostsAreRunningWindows": (.bool, .pseudo),
        "links-aux": (.bool, .pseudo),
        "rsrc-aux": (.bool, .pseudo),
        "someHostIsInsensitive": (.bool, .pseudo),
        "someHostIsRunningWindows": (.bool, .pseudo),
        "unicodeCS": (.bool, .pseudo),
        "unicodeEnc": (.bool, .pseudo),
        // createInt
        "copymax": (.int, none),
        "copythreshold": (.int, none),
        "height": (.int, none),
        "maxbackups": (.int, none),
        "maxerrors": (.int, none),
        "maxsizethreshold": (.int, none),
        "maxthreads": (.int, none),
        "perms": (.int, none),
        "retry": (.int, none),
        // createString
        "addprefsto": (.string, none),
        "backupdir": (.string, none),
        "backuploc": (.string, none),
        "backupprefix": (.string, none),
        "backupsuffix": (.string, none),
        "clientHostName": (.string, none),
        "copyprog": (.string, none),
        "copyprogrest": (.string, none),
        "diff": (.string, none),
        "force": (.string, none),
        "key": (.string, none),
        "label": (.string, none),
        "logfile": (.string, none),
        "prefer": (.string, none),
        "servercmd": (.string, none),
        "sshargs": (.string, none),
        "sshcmd": (.string, none),
        // createString, command-line only
        "doc": (.string, .commandLineOnly),
        "listen": (.string, .commandLineOnly),
        "prefsman": (.string, .commandLineOnly),
        "socket": (.string, .commandLineOnly),
        // createString, pseudo
        "rootsName": (.string, .pseudo),
        // createStringList
        "debug": (.list, none),
        "mountpoint": (.list, none),
        "nocreation": (.list, none),
        "nodeletion": (.list, none),
        "noupdate": (.list, none),
        "root": (.list, none),
        "rootalias": (.list, none),
        "rest": (.list, .commandLineOnly),
        // Pred.create (pattern lists)
        "atomic": (.list, none),
        "backup": (.list, none),
        "backupcurr": (.list, none),
        "backupcurrnot": (.list, none),
        "backupnot": (.list, none),
        "follow": (.list, none),
        "forcepartial": (.list, none),
        "ignore": (.list, none),
        "ignorenot": (.list, none),
        "immutable": (.list, none),
        "immutablenot": (.list, none),
        "merge": (.list, none),
        "nocreationpartial": (.list, none),
        "nodeletionpartial": (.list, none),
        "noupdatepartial": (.list, none),
        "preferpartial": (.list, none),
        "sortfirst": (.list, none),
        "sortlast": (.list, none),
        "xattrignore": (.list, none),
        "xattrignorenot": (.list, none),
        // custom `create`: `path` accumulates, the others are scalars with
        // their own parsers.
        "path": (.list, none),
        "repeat": (.custom, none),
        "ui": (.custom, .commandLineOnly),
        "include": (.custom, .commandLineOnly),
        "source": (.custom, .commandLineOnly),
        // createBoolWithDefault
        "color": (.custom, none),
        "fastcheck": (.custom, none),
        "ignorecase": (.custom, none),
        "links": (.custom, none),
        "rsrc": (.custom, none),
        "unicode": (.custom, none),
    ]
}
