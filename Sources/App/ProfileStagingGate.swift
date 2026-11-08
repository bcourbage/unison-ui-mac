import Foundation

/// Whether a profile may be opened while interrupted archive operations
/// (abandoned stagings) exist.
///
/// A profile is blocked when it uses an archive that an interrupted operation
/// holds. Which archives it uses comes from its effective roots, with
/// includes followed. When those cannot be resolved, the profile might use any
/// of the held archives, so it is blocked too; that is not proof of ownership,
/// and the wording says so.
enum ProfileStagingGate: Equatable {
    /// Nothing holds an archive this profile uses, or the profile has no
    /// local archives to hold.
    case clear
    /// The profile's own archives overlap these records.
    case confirmed([AbandonedStaging])
    /// The profile's roots cannot be resolved; every blocking record is a
    /// possible overlap and none is attributed to it.
    case unresolved([AbandonedStaging])

    var blocksOpening: Bool {
        if case .clear = self { return false }
        return true
    }

    /// The records to present for recovery.
    var records: [AbandonedStaging] {
        switch self {
        case .clear: return []
        case .confirmed(let r), .unresolved(let r): return r
        }
    }

    /// Explanation shown with the picker's recovery prompt.
    var recoveryContext: String {
        switch self {
        case .clear, .confirmed:
            return "This profile's archives are held by an interrupted maintenance operation."
        case .unresolved:
            return "This profile's roots could not be resolved, so it may use archives held by an "
                + "interrupted maintenance operation. Recover the interrupted operations first."
        }
    }

    /// Refusal sent to a command-line caller instead of opening the profile.
    func refusalMessage(profile name: String) -> String {
        switch self {
        case .clear, .confirmed:
            return "unison-ui-mac did not start \(name); its archives are held by an interrupted "
                + "operation. Complete that recovery in the running app, then run the command again."
        case .unresolved:
            return "unison-ui-mac did not start \(name); its roots could not be resolved, so it may use "
                + "archives held by an interrupted operation. Complete that recovery in the running app, "
                + "then run the command again."
        }
    }

    /// `blockedHashes` and `blockingRecords` describe the interrupted operations
    /// that currently hold archives (`AbandonedStagingScan`).
    ///
    /// The profile is `.unresolved` whenever its archive hashes cannot be
    /// trusted to match a held archive: its roots cannot be resolved, or a
    /// local root is a symlink or cannot be resolved (Unison names an archive
    /// from the canonical path, the hash here from the path as written).
    /// `resolve` is the path resolver, injectable for tests.
    static func evaluate(
        profile: String,
        unisonDirectory: String,
        blockedHashes: Set<String>,
        blockingRecords: [AbandonedStaging],
        hostname: String = ArchiveHash.systemHostname,
        resolve: (String) -> String? = ArchiveMatcher.realpathResolve
    ) -> ProfileStagingGate {
        guard !blockedHashes.isEmpty else { return .clear }
        let roots: [String]
        switch ArchiveHash.effectiveRoots(unisonDirectory: unisonDirectory, profile: profile) {
        case .success(let resolved):
            roots = resolved
        case .failure(let failure):
            switch failure {
            case .rootsUnresolved:
                return .unresolved(blockingRecords)
            case .profileFileMissing:
                return .clear   // the engine cannot open a profile that does not exist
            case .noRoots, .noLocalRoot:
                return .clear   // no local archive exists for it to be held
            }
        }
        let specs = ArchiveMatcher.rootSpecs(forRoots: roots)
        let pathsTrusted = zip(roots, specs).filter { $0.1.isLocal }.allSatisfy { raw, _ in
            let r = ArchiveMatcher.localRootNeedsResolution(raw, resolve: resolve)
            return r.resolvable && !r.differs
        }
        guard pathsTrusted else { return .unresolved(blockingRecords) }
        guard case .success(let computed) = ArchiveHash.computeAll(forRoots: roots, hostname: hostname),
              ArchiveStagingRecovery.isProfileBlocked(profileHashes: computed.hashes, blocked: blockedHashes)
        else { return .clear }
        let mine = Set(computed.hashes)
        return .confirmed(blockingRecords.filter { !Set($0.manifest.hashes).isDisjoint(with: mine) })
    }
}
