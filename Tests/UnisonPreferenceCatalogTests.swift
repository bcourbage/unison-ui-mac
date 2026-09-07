import XCTest
@testable import unison_ui_mac

final class UnisonPreferenceCatalogTests: XCTestCase {
    private typealias C = UnisonPreferenceCatalog

    /// Names the vendored engine (2.54.0, ocaml 5.5.0) printed for `-help`
    /// on 2026-09-07. `scripts/check-pref-catalog.sh` repeats this comparison
    /// against the built engine in CI.
    private static let helpNames = """
    acl addprefsto addversionno atomic auto backup backupcurr backupcurrnot backupdir backuploc backupnot \
    backupprefix backups backupsuffix batch clientHostName color confirmbigdel confirmmerge contactquietly \
    copymax copyonconflict copyprog copyprogrest copythreshold debug diff doc dontchmod dumbtty dumparchives \
    fastcheck fastercheckUNSAFE fat follow force forcepartial group halfduplex height i ignore ignorearchives \
    ignorecase ignoreinodenumbers ignorelocks ignorenot immutable immutablenot include key killserver label \
    links listen log logfile maxbackups maxerrors maxsizethreshold maxthreads merge mountpoint moves-experimental \
    nocreation nocreationpartial nodeletion nodeletionpartial noupdate noupdatepartial numericids owner path \
    perms prefer preferpartial repeat retry root rootalias rsrc rsync selftest servercmd showarchive silent \
    socket sortbysize sortfirst sortlast sortnewfirst source sshargs sshcmd stream terse testserver times ui \
    unicode version watch xattrignore xattrignorenot xattrs xferbycopying
    """.split(separator: " ").map(String.init)

    func test_everyHelpName_isRegistered() {
        XCTAssertEqual(Self.helpNames.count, 106)
        for name in Self.helpNames {
            XCTAssertNotNil(C.entry(for: name), "\(name) is printed by -help but missing from the catalog")
        }
    }

    func test_helpVisibleNames_equalTheHelpOutput() {
        // Both directions: nothing -help prints is missing, and nothing the
        // catalog calls help-visible is absent from -help.
        XCTAssertEqual(C.helpVisibleNames, Set(Self.helpNames))
    }

    func test_internalRegistrations_areAcceptedButNotHelpVisible() {
        for name in ["expert", "showprev", "debugtimes", "timers", "keeptempfilesaftermerge"] {
            let e = C.entry(for: name)
            XCTAssertEqual(e?.isInternal, true, name)
            XCTAssertEqual(e?.pseudo, false, name)
            XCTAssertEqual(e?.commandLineOnly, false, name)
        }
        for name in ["prefsdocs", "prefsman", "server", "rest"] {
            XCTAssertEqual(C.entry(for: name)?.isInternal, true, name)
            XCTAssertEqual(C.entry(for: name)?.commandLineOnly, true, name)
        }
        XCTAssertEqual(C.entry(for: "rootsName")?.isInternal, true)
        XCTAssertEqual(C.entry(for: "servercmd")?.isInternal, false)
    }

    func test_kinds() {
        XCTAssertEqual(C.entry(for: "servercmd"), .init(name: "servercmd", kind: .string, commandLineOnly: false, pseudo: false, isInternal: false))
        XCTAssertEqual(C.entry(for: "addversionno")?.kind, .bool)
        XCTAssertEqual(C.entry(for: "maxthreads")?.kind, .int)
        XCTAssertEqual(C.entry(for: "root")?.kind, .list)
        XCTAssertEqual(C.entry(for: "path")?.kind, .list)
        XCTAssertEqual(C.entry(for: "ignore")?.kind, .list)
        XCTAssertEqual(C.entry(for: "fastcheck")?.kind, .custom)
        XCTAssertEqual(C.entry(for: "repeat")?.kind, .custom)
        XCTAssertTrue(C.ValueKind.list.accumulates)
        XCTAssertFalse(C.ValueKind.string.accumulates)
    }

    func test_commandLineOnly() {
        for name in ["ui", "server", "socket", "version", "doc", "i", "listen", "selftest", "testserver",
                     "dumparchives", "prefsdocs", "prefsman", "rest", "include", "source"] {
            XCTAssertEqual(C.entry(for: name)?.commandLineOnly, true, name)
        }
        XCTAssertEqual(C.entry(for: "servercmd")?.commandLineOnly, false)
    }

    func test_pseudo_registrations() {
        for name in ["rootsName", "someHostIsRunningWindows", "allHostsAreRunningWindows", "unicodeEnc",
                     "unicodeCS", "someHostIsInsensitive", "links-aux", "rsrc-aux"] {
            XCTAssertEqual(C.entry(for: name)?.pseudo, true, name)
        }
    }

    func test_aliases_resolveToTheirTarget() {
        XCTAssertEqual(C.entry(for: "mirror"), C.entry(for: "backup"))
        XCTAssertEqual(C.entry(for: "host"), C.entry(for: "listen"))
        XCTAssertEqual(C.entry(for: "host")?.commandLineOnly, true)
        XCTAssertEqual(C.entry(for: "pretendwin")?.name, "ignoreinodenumbers")
        XCTAssertEqual(C.entry(for: "backupversions")?.name, "maxbackups")
        XCTAssertEqual(C.entry(for: "confirmbigdeletes")?.name, "confirmbigdel")
    }

    func test_unknownName_isNil() {
        XCTAssertNil(C.entry(for: "servercommand"))
        XCTAssertNil(C.entry(for: "Servercmd"))
        XCTAssertNil(C.entry(for: ""))
    }
}
