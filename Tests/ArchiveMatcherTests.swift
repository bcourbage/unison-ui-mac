import XCTest
@testable import unison_ui_mac

/// Tests for `ArchiveMatcher` — hostname-agnostic, path-based matching of
/// archive files to profiles. Cases mirror the real profiles that drove
/// the design: local↔local, local↔ssh (absolute remote path), local↔ssh
/// (remote home), hostname drift (`.local` → bare), and a shared local
/// root that must NOT cross-match.
final class ArchiveMatcherTests: XCTestCase {

    private func entry(_ hash: String,
                       thisRoot: String,
                       roots: String) -> ArchiveCleanup.ArchiveEntry {
        ArchiveCleanup.ArchiveEntry(
            url: URL(fileURLWithPath: "/tmp/ar\(hash)"),
            hash: hash, thisRoot: thisRoot, rootsName: roots)
    }

    // MARK: - Parsing

    func test_remotePath_absoluteDoubleSlash() {
        XCTAssertEqual(
            ArchiveMatcher.remotePath(of: "ssh://bcourbage@192.168.2.35//Volumes/Media/FlightSim"),
            "/Volumes/Media/FlightSim")
    }

    func test_remotePath_bareHomeIsNil() {
        XCTAssertNil(ArchiveMatcher.remotePath(of: "ssh://bcourbage@192.168.2.35/"))
    }

    func test_remotePath_relativeToHomeIsNil() {
        XCTAssertNil(ArchiveMatcher.remotePath(of: "ssh://host/relative/path"))
    }

    func test_fspath_stripsHostKeepsAbsolutePath() {
        XCTAssertEqual(ArchiveMatcher.fspath(ofComponent: "//Demeter//Volumes/Media/FlightSim"),
                       "/Volumes/Media/FlightSim")
        XCTAssertEqual(ArchiveMatcher.fspath(ofComponent: "//Heracles.local//Users/bcourbage"),
                       "/Users/bcourbage")
    }

    // MARK: - Matching

    private func matches(_ roots: [String],
                         _ index: [ArchiveCleanup.ArchiveEntry],
                         host: String = "Heracles") -> Set<String> {
        Set(ArchiveMatcher.archives(forProfileRoots: roots, in: index, localHostname: host).map(\.hash))
    }

    func test_localSsh_matchesAcrossSuffixDrift() {
        // FlightSim: archive written under `.local`; current name is bare.
        // Same hostname lineage (`heracles`), so it must still match.
        let roots = ["/Volumes/FlightSim",
                     "ssh://bcourbage@192.168.2.35//Volumes/Media/FlightSim"]
        let index = [
            entry("a", thisRoot: "//Heracles.local//Volumes/FlightSim",
                  roots: "//Demeter.local//Volumes/Media/FlightSim, //Heracles.local//Volumes/FlightSim")
        ]
        XCTAssertEqual(matches(roots, index, host: "Heracles"), ["a"])
    }

    private func live(_ roots: [String],
                      _ index: [ArchiveCleanup.ArchiveEntry],
                      host: String = "Heracles") -> Set<String> {
        Set(ArchiveMatcher.liveArchives(forProfileRoots: roots, in: index, localHostname: host).map(\.hash))
    }

    func test_liveArchives_prefersCurrentHostnameGeneration() {
        // OneDrive: current `Heracles` pair + stale `Heracles.local` pair.
        // Live = only the current pair (next sync uses those).
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
        XCTAssertEqual(live(roots, index), ["curPics", "curOD"])
    }

    func test_liveArchives_noCurrentGeneration_isEmpty() {
        // FlightSim: only a `.local` archive exists (not synced since the
        // rename). The next sync won't use it (wrong hostname hash), so it
        // is NOT live — there's simply no live archive. (The `.local` copy
        // is stale and handled by Clean Stale, not Reset.)
        let roots = ["/Volumes/FlightSim",
                     "ssh://bcourbage@192.168.2.35//Volumes/Media/FlightSim"]
        let index = [
            entry("a", thisRoot: "//Heracles.local//Volumes/FlightSim",
                  roots: "//Demeter.local//Volumes/Media/FlightSim, //Heracles.local//Volumes/FlightSim")
        ]
        XCTAssertTrue(live(roots, index, host: "Heracles").isEmpty)
    }

    func test_formerMachineName_excludedEvenWithKnownPaths() {
        // An all-local profile's archive written under a FORMER machine
        // name (MacBookPro) is a stale orphan, not this profile's current
        // state. Excluded from the per-profile match despite path equality.
        let roots = ["/Users/bcourbage/Documents",
                     "/Users/bcourbage/Library/Mobile Documents/com~apple~CloudDocs/Backup/Documents"]
        let pairCur = "//Heracles//Users/bcourbage/Documents, //Heracles//Users/bcourbage/Library/Mobile Documents/com~apple~CloudDocs/Backup/Documents"
        let pairOld = "//MacBookPro//Users/bcourbage/Documents, //MacBookPro//Users/bcourbage/Library/Mobile Documents/com~apple~CloudDocs/Backup/Documents"
        let index = [
            entry("cur", thisRoot: "//Heracles//Users/bcourbage/Documents", roots: pairCur),
            entry("old", thisRoot: "//MacBookPro//Users/bcourbage/Documents", roots: pairOld),
        ]
        XCTAssertEqual(matches(roots, index, host: "Heracles"), ["cur"])
    }

    func test_wildcardRemote_pinsToHostnameLineage() {
        // Home-Demeter: remote is the remote home (wildcard). Only this
        // machine's hostname lineage should match — current + `.local`,
        // but NOT a former machine name or test junk.
        let roots = ["/Users/bcourbage/", "ssh://bcourbage@192.168.2.35/"]
        let index = [
            entry("current", thisRoot: "//Heracles//Users/bcourbage",
                  roots: "//Demeter//Users/bcourbage, //Heracles//Users/bcourbage"),
            entry("staleLocal", thisRoot: "//Heracles.local//Users/bcourbage",
                  roots: "//Demeter.local//Users/bcourbage, //Heracles.local//Users/bcourbage"),
            entry("oldMachine", thisRoot: "//MacBookPro//Users/bcourbage",
                  roots: "//Demeter.local//Users/bcourbage, //MacBookPro//Users/bcourbage"),
            entry("testJunk", thisRoot: "//ArchiveMissTest//Users/bcourbage",
                  roots: "//ArchiveMissTest//Users/bcourbage, //Demeters//Users/bcourbage"),
        ]
        XCTAssertEqual(matches(roots, index, host: "Heracles"), ["current", "staleLocal"])
    }

    func test_sharedLocalRoot_remotePathDisambiguates() {
        // Two profiles both rooted at …/Pictures locally: one ssh→Demeter
        // (/Volumes/Media/Pictures), one local↔local→OneDrive. The ssh
        // profile must match ONLY its own archive.
        let demeterPicsRoots = ["/Users/bcourbage/Pictures",
                                "ssh://bcourbage@192.168.2.35//Volumes/Media/Pictures"]
        let index = [
            entry("demeter", thisRoot: "//Heracles//Users/bcourbage/Pictures",
                  roots: "//Demeter//Volumes/Media/Pictures, //Heracles//Users/bcourbage/Pictures"),
            entry("onedrive", thisRoot: "//Heracles//Users/bcourbage/Pictures",
                  roots: "//Heracles//Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures, //Heracles//Users/bcourbage/Pictures"),
        ]
        XCTAssertEqual(matches(demeterPicsRoots, index), ["demeter"])
    }

    func test_localLocal_matchesBothSidesAndStaleCopy() {
        // OneDrive: both replicas local → two archives (one per thisRoot).
        // A stale `.local` copy of the same pair must also match.
        let roots = ["/Users/bcourbage/Pictures",
                     "/Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures"]
        let pair = "//Heracles//Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures, //Heracles//Users/bcourbage/Pictures"
        let stalePair = "//Heracles.local//Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures, //Heracles.local//Users/bcourbage/Pictures"
        let index = [
            entry("picsSide", thisRoot: "//Heracles//Users/bcourbage/Pictures", roots: pair),
            entry("odSide", thisRoot: "//Heracles//Users/bcourbage/Library/CloudStorage/OneDrive-Personal/Pictures", roots: pair),
            entry("stale", thisRoot: "//Heracles.local//Users/bcourbage/Pictures", roots: stalePair),
        ]
        let matched = ArchiveMatcher.archives(forProfileRoots: roots, in: index, localHostname: "Heracles")
        XCTAssertEqual(Set(matched.map(\.hash)), ["picsSide", "odSide", "stale"])
        // All three are the same root-pair by path signature → not ambiguous.
        XCTAssertEqual(Set(matched.map { ArchiveMatcher.pathSignature(ofRootsName: $0.rootsName) }).count, 1)
    }

    func test_remoteHome_localSidePinsMatch() {
        // Home-Demeter: remote path is the remote home (unknown offline),
        // so it's a wildcard; the local /Users/bcourbage side pins it.
        let roots = ["/Users/bcourbage/", "ssh://bcourbage@192.168.2.35/"]
        let index = [
            entry("home", thisRoot: "//Heracles//Users/bcourbage",
                  roots: "//Demeter//Users/bcourbage, //Heracles//Users/bcourbage"),
            entry("pics", thisRoot: "//Heracles//Users/bcourbage/Pictures",
                  roots: "//Demeter//Volumes/Media/Pictures, //Heracles//Users/bcourbage/Pictures"),
        ]
        XCTAssertEqual(matches(roots, index), ["home"])
    }

    func test_noMatch_whenLocalRootAbsent() {
        let roots = ["/Users/bcourbage/Documents",
                     "ssh://host//data"]
        let index = [
            entry("x", thisRoot: "//Heracles//Volumes/FlightSim",
                  roots: "//Demeter//Volumes/Media/FlightSim, //Heracles//Volumes/FlightSim")
        ]
        XCTAssertTrue(matches(roots, index).isEmpty)
    }

    func test_allRemoteProfile_matchesNothing() {
        // No local root → nothing on this machine to match.
        let roots = ["ssh://a//x", "ssh://b//y"]
        let index = [entry("z", thisRoot: "//A//x", roots: "//A//x, //B//y")]
        XCTAssertTrue(matches(roots, index).isEmpty)
    }
}
