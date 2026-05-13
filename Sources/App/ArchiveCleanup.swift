import Foundation

/// Finds and trashes the local archive files for a given hash. Used by
/// the proactive "Reset Archives" action in the Profile Editor.
///
/// Unison stores five files per local replica, all keyed off the same
/// MD5 hash suffix (see `ArchiveHash`):
///
///     ar<hash>   The archive itself (mainArch).
///     fp<hash>   Fingerprint cache (FPCache).
///     lk<hash>   Lock file (Lock). Only present during an active sync.
///     tm<hash>   Temporary in-progress archive (NewArch). Rare — should
///                only exist if a previous sync crashed mid-write.
///     sc<hash>   Scratch archive (ScratchArch). Same — crash artifact.
///
/// The five-prefix list mirrors `Update.archiveName`'s switch on
/// `archiveVersion`. We err on the side of cleaning up the crash-only
/// variants too: if the user is hitting Reset Archives, it's because
/// something went wrong and we want a clean slate.
///
/// All deletions go through `FileManager.trashItem(at:)` so a misclick
/// is recoverable from Finder's Trash. The user can drag the files
/// back into the Unison directory if they regret it.
struct ArchiveCleanup {

    /// The five archive-file prefixes in upstream's `archiveVersion`
    /// enum order. Each maps to a kind of archive Unison may have
    /// written for the same logical replica state.
    static let archivePrefixes = ["ar", "fp", "lk", "tm", "sc"]

    let unisonDirectory: String

    /// Find the local files matching the given hash, returning the
    /// absolute URLs in `archivePrefixes` order (so the caller can
    /// display them grouped meaningfully). Missing files are omitted.
    func findFiles(matching hash: String) -> [URL] {
        let fm = FileManager.default
        let baseDir = URL(fileURLWithPath: unisonDirectory)
        return Self.archivePrefixes.compactMap { prefix in
            let url = baseDir.appendingPathComponent("\(prefix)\(hash)")
            return fm.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Move each file in `urls` to Trash. Returns the URLs that
    /// successfully moved (and a parallel list of failures with the
    /// underlying error, for surfacing in the UI).
    @discardableResult
    func trash(_ urls: [URL]) -> (trashed: [URL], failed: [(URL, Error)]) {
        let fm = FileManager.default
        var trashed: [URL] = []
        var failed: [(URL, Error)] = []
        for url in urls {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                trashed.append(url)
            } catch {
                failed.append((url, error))
            }
        }
        return (trashed, failed)
    }
}
