import Foundation

/// Classifies the archives in the Unison directory against the set of
/// current profiles, to find ones safe to remove. An archive is "stale"
/// when it is NOT the live generation of any profile — either:
///   - `.superseded`: it matches a current profile by paths and hostname
///     lineage, but a newer (current-hostname) copy supersedes it
///     (e.g. a `Heracles.local` archive left behind after a rename), or
///   - `.orphan`: it matches no current profile at all (a deleted
///     profile's archive, or one from a former machine identity).
///
/// Live archives — what each profile's next sync actually uses — are
/// never flagged. The classification reuses the exact matching logic the
/// Reset feature uses (`ArchiveMatcher`), so the two stay consistent.
enum ArchiveStaleScanner {

    enum Reason: Equatable {
        /// Attributable to a current profile (an old/superseded copy).
        case superseded
        /// Matches no current profile.
        case orphan

        var label: String {
            switch self {
            case .superseded: return "old or superseded copy"
            case .orphan:     return "no matching profile"
            }
        }
    }

    /// A current profile: its name and its `root = …` values.
    struct Profile: Equatable {
        let name: String
        let roots: [String]
        /// False when something defeats path-based attribution for this
        /// profile (it uses `rootalias`, has a symlinked root, or is a
        /// home-dir ssh profile sharing its local root). Findings touching
        /// such a profile are marked uncertain. Computed by the caller.
        let attributionReliable: Bool
        init(name: String, roots: [String], attributionReliable: Bool = true) {
            self.name = name
            self.roots = roots
            self.attributionReliable = attributionReliable
        }
    }

    struct Finding: Equatable {
        let entry: ArchiveCleanup.ArchiveEntry
        let reason: Reason
        /// Profiles this archive is attributable to (empty when orphaned).
        let profileNames: [String]
        /// True when this attribution can't be fully trusted (it involves,
        /// or could involve, an attribution-unreliable profile).
        let uncertain: Bool
    }

    /// Archives that are not the live generation of any profile.
    ///
    /// - `index`: all `ar*` archives (from `ArchiveCleanup.indexArchives`).
    /// - `profiles`: each current profile's name + `root = …` values.
    /// - `localHostname`: this machine's hostname (POSIX `gethostname`).
    ///
    /// An archive is *live* (excluded) when it matches a profile under the
    /// exact current hostname. A non-live archive that still matches a
    /// profile by paths + hostname lineage (e.g. a `Heracles.local` copy)
    /// is attributed to that profile and marked `.superseded`; one that
    /// matches no profile is an `.orphan`.
    static func findings(in index: [ArchiveCleanup.ArchiveEntry],
                         profiles: [Profile],
                         localHostname: String) -> [Finding] {
        let current = localHostname.lowercased()
        let unreliableNames = Set(profiles.filter { !$0.attributionReliable }.map(\.name))
        var liveHashes = Set<String>()
        var hashToNames: [String: Set<String>] = [:]
        for profile in profiles {
            for entry in ArchiveMatcher.archives(forProfileRoots: profile.roots,
                                                 in: index, localHostname: localHostname) {
                hashToNames[entry.hash, default: []].insert(profile.name)
                if ArchiveMatcher.host(ofComponent: entry.thisRoot)?.lowercased() == current {
                    liveHashes.insert(entry.hash)
                }
            }
        }
        return index
            .filter { !liveHashes.contains($0.hash) }
            .map { entry in
                let names = (hashToNames[entry.hash] ?? []).sorted()
                // Attributed → uncertain if any owning profile is
                // unreliable. Orphan → uncertain if any unreliable profile
                // exists at all, since it could secretly own this archive
                // (rootalias/symlink would hide the match).
                let uncertain = names.isEmpty
                    ? !unreliableNames.isEmpty
                    : !Set(names).isDisjoint(with: unreliableNames)
                return Finding(entry: entry,
                               reason: names.isEmpty ? .orphan : .superseded,
                               profileNames: names,
                               uncertain: uncertain)
            }
    }
}
