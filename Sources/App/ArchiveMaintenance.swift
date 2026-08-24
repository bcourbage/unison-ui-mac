import Foundation

/// The ONE place every destructive archive operation (Clean Stale, Reset,
/// delete-with-archives, fatal recovery) routes through. It builds an
/// `ArchiveMutationPlan` (which excludes `lk` by construction) and runs it
/// through the crash-safe `ArchiveMutation` transaction with the real
/// interprocess lock (`SystemArchiveLocking`) and the POSIX staging store.
///
/// Raw `FileManager.trashItem`/`removeItem` of archive files must not be used
/// anywhere else — this is the sole mutation authority, so `lk` is never
/// trashed, a live Unison's lock always blocks, and a mid-mutation failure can
/// never leave a partial archive family.
enum ArchiveMaintenance {

    /// Run a destructive mutation over the given archive hashes. The exact
    /// payload family is derived UNDER the acquired locks; `revalidate` receives
    /// that under-lock plan and must re-confirm it is still safe to remove
    /// (returning false aborts without touching any payload).
    static func mutate(operation: String,
                       hashes: [String],
                       unisonDirectory: String,
                       isEngineIdle: () -> Bool,
                       revalidate: (ArchiveMutationPlan) -> Bool,
                       now: Date = Date(),
                       locking: ArchiveLocking = SystemArchiveLocking(),
                       store: ArchivePayloadStore? = nil)
        -> Result<ArchiveMutationOutcome, Error> {
        let fm = FileManager.default
        let iso = ISO8601DateFormatter()
        let store = store ?? POSIXStagingStore(unisonDir: unisonDirectory)
        do {
            let out = try ArchiveMutation.execute(
                operation: operation, hashes: hashes, nowISO8601: iso.string(from: now),
                isEngineIdle: isEngineIdle,
                fileExists: { name in
                    fm.fileExists(atPath: (unisonDirectory as NSString).appendingPathComponent(name))
                },
                revalidate: revalidate, locking: locking, store: store)
            return .success(out)
        } catch {
            return .failure(error)
        }
    }
}
