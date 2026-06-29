import XCTest
@testable import unison_ui_mac

/// Tests for `ArchiveStaleScanner` — classifying archives that no current
/// profile uses, attributing each to a profile where possible (an old or
/// superseded copy) or marking it an orphan, while never flagging the
/// live (exact current-hostname) ones.
final class ArchiveStaleScannerTests: XCTestCase {

    private func entry(_ hash: String,
                       thisRoot: String,
                       roots: String) -> ArchiveCleanup.ArchiveEntry {
        ArchiveCleanup.ArchiveEntry(
            url: URL(fileURLWithPath: "/tmp/ar\(hash)"),
            hash: hash, thisRoot: thisRoot, rootsName: roots)
    }

    private func find(_ index: [ArchiveCleanup.ArchiveEntry],
                      _ profiles: [ArchiveStaleScanner.Profile],
                      host: String = "Heracles") -> [ArchiveStaleScanner.Finding] {
        ArchiveStaleScanner.findings(in: index, profiles: profiles, localHostname: host)
    }

    private func profile(_ name: String, _ roots: [String]) -> ArchiveStaleScanner.Profile {
        ArchiveStaleScanner.Profile(name: name, roots: roots)
    }

    func test_liveArchive_isNotFlagged() {
        let roots = ["/Users/bcourbage/Pictures",
                     "/Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures"]
        let pair = "//Heracles//Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures, //Heracles//Users/bcourbage/Pictures"
        let index = [
            entry("pics", thisRoot: "//Heracles//Users/bcourbage/Pictures", roots: pair),
            entry("od", thisRoot: "//Heracles//Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures", roots: pair),
        ]
        XCTAssertTrue(find(index, [profile("Sync-Pics-OneDrive", roots)]).isEmpty)
    }

    func test_olderHostnameGeneration_isSupersededAndAttributed() {
        let roots = ["/Users/bcourbage/Pictures",
                     "/Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures"]
        let cur = "//Heracles//Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures, //Heracles//Users/bcourbage/Pictures"
        let stale = "//Heracles.local//Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures, //Heracles.local//Users/bcourbage/Pictures"
        let index = [
            entry("curPics", thisRoot: "//Heracles//Users/bcourbage/Pictures", roots: cur),
            entry("curOD", thisRoot: "//Heracles//Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures", roots: cur),
            entry("stalePics", thisRoot: "//Heracles.local//Users/bcourbage/Pictures", roots: stale),
            entry("staleOD", thisRoot: "//Heracles.local//Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures", roots: stale),
        ]
        let findings = find(index, [profile("Sync-Pics-OneDrive", roots)])
        XCTAssertEqual(Set(findings.map(\.entry.hash)), ["stalePics", "staleOD"])
        XCTAssertTrue(findings.allSatisfy { $0.reason == .superseded })
        XCTAssertTrue(findings.allSatisfy { $0.profileNames == ["Sync-Pics-OneDrive"] })
    }

    func test_sharedRootPair_attributesAllOwningProfiles() {
        // Two profiles with the same roots (…-Fix variant) both own the
        // archive, so both names appear.
        let roots = ["/Users/bcourbage/Pictures",
                     "/Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures"]
        let cur = "//Heracles//Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures, //Heracles//Users/bcourbage/Pictures"
        let stale = "//Heracles.local//Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures, //Heracles.local//Users/bcourbage/Pictures"
        let index = [
            entry("cur", thisRoot: "//Heracles//Users/bcourbage/Pictures", roots: cur),
            entry("stale", thisRoot: "//Heracles.local//Users/bcourbage/Pictures", roots: stale),
        ]
        let findings = find(index, [profile("Sync-Pics-OneDrive", roots),
                                    profile("Sync-Pics-OneDrive-Fix", roots)])
        XCTAssertEqual(findings.map(\.entry.hash), ["stale"])
        XCTAssertEqual(findings.first?.profileNames,
                       ["Sync-Pics-OneDrive", "Sync-Pics-OneDrive-Fix"])
    }

    func test_formerMachineName_isOrphan() {
        // A former-machine (MacBookPro) archive is a different hostname
        // lineage, so it isn't attributed to the current profile → orphan.
        let roots = ["/Users/bcourbage/Documents",
                     "/Users/bcourbage/Library/Mobile Documents/com~apple~CloudDocs/Backup/Documents"]
        let cur = "//Heracles//Users/bcourbage/Documents, //Heracles//Users/bcourbage/Library/Mobile Documents/com~apple~CloudDocs/Backup/Documents"
        let old = "//MacBookPro//Users/bcourbage/Documents, //MacBookPro//Users/bcourbage/Library/Mobile Documents/com~apple~CloudDocs/Backup/Documents"
        let index = [
            entry("curDocs", thisRoot: "//Heracles//Users/bcourbage/Documents", roots: cur),
            entry("curBackup", thisRoot: "//Heracles//Users/bcourbage/Library/Mobile Documents/com~apple~CloudDocs/Backup/Documents", roots: cur),
            entry("oldDocs", thisRoot: "//MacBookPro//Users/bcourbage/Documents", roots: old),
        ]
        let findings = find(index, [profile("Sync-Documents-iCloud", roots)])
        XCTAssertEqual(findings.map(\.entry.hash), ["oldDocs"])
        XCTAssertEqual(findings.first?.reason, .orphan)
        XCTAssertEqual(findings.first?.profileNames, [])
    }

    func test_noCurrentGeneration_attributedToProfile() {
        // FlightSim: only a `.local` archive, no live copy, but it still
        // belongs to the profile (same hostname lineage) → superseded,
        // attributed to Sync-FlightSim.
        let roots = ["/Volumes/FlightSim",
                     "ssh://bcourbage@192.168.2.35//Volumes/Media/FlightSim"]
        let index = [
            entry("fs", thisRoot: "//Heracles.local//Volumes/FlightSim",
                  roots: "//Demeter.local//Volumes/Media/FlightSim, //Heracles.local//Volumes/FlightSim")
        ]
        let findings = find(index, [profile("Sync-FlightSim", roots)])
        XCTAssertEqual(findings.map(\.entry.hash), ["fs"])
        XCTAssertEqual(findings.first?.reason, .superseded)
        XCTAssertEqual(findings.first?.profileNames, ["Sync-FlightSim"])
    }

    func test_deletedProfile_archiveIsOrphan() {
        let index = [
            entry("gone", thisRoot: "//Heracles//Users/bcourbage/OldProject",
                  roots: "//Demeter//data/OldProject, //Heracles//Users/bcourbage/OldProject")
        ]
        let findings = find(index, [profile("Sync-Pics", ["/Users/bcourbage/Pictures", "/Users/bcourbage/Documents"])])
        XCTAssertEqual(findings.map(\.entry.hash), ["gone"])
        XCTAssertEqual(findings.first?.reason, .orphan)
    }

    func test_noProfiles_everythingIsOrphan() {
        let index = [entry("a", thisRoot: "//Heracles//x", roots: "//Heracles//x, //Heracles//y")]
        XCTAssertEqual(find(index, []).map(\.reason), [.orphan])
    }

    func test_attribution_uncertainWhenOwningProfileUnreliable() {
        let roots = ["/Volumes/FlightSim",
                     "ssh://bcourbage@192.168.2.35//Volumes/Media/FlightSim"]
        let index = [
            entry("fs", thisRoot: "//Heracles.local//Volumes/FlightSim",
                  roots: "//Demeter.local//Volumes/Media/FlightSim, //Heracles.local//Volumes/FlightSim")
        ]
        XCTAssertEqual(find(index, [profile("Sync-FlightSim", roots)]).first?.uncertain, false)
        let unreliable = ArchiveStaleScanner.Profile(
            name: "Sync-FlightSim", roots: roots, attributionReliable: false)
        XCTAssertEqual(find(index, [unreliable]).first?.uncertain, true)
    }

    func test_orphan_uncertainOnlyWhenAnUnreliableProfileExists() {
        let index = [
            entry("gone", thisRoot: "//Heracles//Users/bcourbage/OldProject",
                  roots: "//Demeter//data/OldProject, //Heracles//Users/bcourbage/OldProject")
        ]
        let otherRoots = ["/Users/bcourbage/Pictures", "/Users/bcourbage/Documents"]
        XCTAssertEqual(find(index, [profile("X", otherRoots)]).first?.uncertain, false)
        let unreliable = ArchiveStaleScanner.Profile(
            name: "X", roots: otherRoots, attributionReliable: false)
        XCTAssertEqual(find(index, [unreliable]).first?.uncertain, true)
    }
}
