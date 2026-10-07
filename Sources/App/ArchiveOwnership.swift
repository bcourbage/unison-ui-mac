import Foundation

/// Decides whether a profile's live archives may be removed along with the
/// profile, by checking whether any OTHER current profile still uses them.
///
/// Unison names an archive by its root pair, so two profiles with the same
/// roots share one archive family. Removing that family when one of them is
/// deleted makes the survivor's next run a first sync: a file deleted on one
/// side is copied back from the other instead of being deleted, and real
/// conflicts can appear. The delete flow therefore offers archive removal only
/// when this verdict proves no other profile owns the archives, and leaves them
/// in place whenever ownership cannot be established.
enum ArchiveOwnership {

    /// A current profile other than the one being deleted.
    struct Profile: Equatable {
        let name: String
        /// Its `root = …` values after include/source resolution.
        let roots: [String]
        /// False when the roots cannot be trusted to describe what the profile
        /// really syncs: an include or source did not resolve, the profile uses
        /// `rootalias`, or a local root is a symlink. Such a profile might own
        /// archives its visible roots do not match, so it is treated as a
        /// possible owner (fail closed).
        let rootsReliable: Bool
        init(name: String, roots: [String], rootsReliable: Bool = true) {
            self.name = name
            self.roots = roots
            self.rootsReliable = rootsReliable
        }
    }

    struct Verdict: Equatable {
        /// Other profiles whose roots match at least one of the hashes, sorted.
        let otherOwners: [String]
        /// Other profiles whose roots are not reliable and so might own the
        /// archives without matching them, sorted.
        let unresolvedProfiles: [String]
        /// True when the profile directory could not be read at all, so the
        /// set of other profiles is unknown.
        let enumerationFailed: Bool

        init(otherOwners: [String], unresolvedProfiles: [String], enumerationFailed: Bool = false) {
            self.otherOwners = otherOwners
            self.unresolvedProfiles = unresolvedProfiles
            self.enumerationFailed = enumerationFailed
        }

        /// True only when the other profiles are known, none of them matches,
        /// and every one of them has reliable roots. Deletion authority over
        /// the archives comes from this, never from the deleting profile's own
        /// match alone.
        var removalPermitted: Bool {
            !enumerationFailed && otherOwners.isEmpty && unresolvedProfiles.isEmpty
        }
    }

    /// Ownership of `hashes` (the deleting profile's archive hashes) among
    /// `others` (every current profile except the one being deleted).
    ///
    /// Matching uses `ArchiveMatcher.archives`, so another profile owns a hash
    /// when its roots match the archive by path and hostname lineage, exactly
    /// as Reset and Clean Stale Archives attribute archives.
    static func verdict(hashes: [String],
                        others: [Profile],
                        index: [ArchiveCleanup.ArchiveEntry],
                        localHostname: String) -> Verdict {
        let wanted = Set(hashes)
        guard !wanted.isEmpty else {
            return Verdict(otherOwners: [], unresolvedProfiles: [])
        }
        var owners = Set<String>()
        var unresolved = Set<String>()
        for other in others {
            if !other.rootsReliable { unresolved.insert(other.name) }
            let matched = ArchiveMatcher.archives(forProfileRoots: other.roots,
                                                  in: index, localHostname: localHostname)
            if matched.contains(where: { wanted.contains($0.hash) }) {
                owners.insert(other.name)
            }
        }
        // A profile that provably matches is reported as an owner, not as
        // unresolved, so the message names the concrete conflict.
        unresolved.subtract(owners)
        return Verdict(otherOwners: owners.sorted(), unresolvedProfiles: unresolved.sorted())
    }

    /// Every `.prf` in `unisonDirectory` except `excluding`, with roots
    /// resolved through `include`/`source` and reliability judged per
    /// `Profile.rootsReliable`. Hidden profiles are included: hiding is a
    /// picker preference and does not stop a profile from syncing.
    ///
    /// Returns nil when the directory cannot be enumerated, since an empty
    /// result would wrongly prove that nothing else owns the archives.
    static func otherProfiles(unisonDirectory: String,
                              excluding deleting: String,
                              isSymlink: (String) -> Bool = ArchiveOwnership.isLeafSymlink) -> [Profile]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: unisonDirectory) else {
            return nil
        }
        return names
            .filter { ($0 as NSString).pathExtension == "prf" }
            .map { ($0 as NSString).deletingPathExtension }
            .filter { $0 != deleting }
            .sorted()
            .map { name in
                let resolution = ProfileRootResolver.resolve(
                    unisonDirectory: unisonDirectory, profile: name)
                let localPaths = ArchiveMatcher.rootSpecs(forRoots: resolution.roots)
                    .filter { $0.isLocal }
                    .compactMap { $0.path }
                let reliable = resolution.reliable
                    && resolution.rootaliases.isEmpty
                    && !localPaths.contains(where: isSymlink)
                return Profile(name: name, roots: resolution.roots, rootsReliable: reliable)
            }
    }

    /// True when the path itself is a symbolic link (its canonical location
    /// differs from the `.prf` text, so path matching could miss it).
    static func isLeafSymlink(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: expanded)) != nil
    }
}
