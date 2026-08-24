import Foundation

enum ArchiveStoreError: Error, Equatable {
    case notStaging
    case createQuarantineFailed(Int32)
    case manifestWriteFailed(Int32)
    case renameFailed(name: String, errno: Int32)
    case trashFailed(String)
    /// A rollback could not restore every staged file. The quarantine + manifest
    /// are RETAINED (nothing deleted) at this path; recovery is explicit.
    case rollbackIncomplete(String)
}

/// Production `ArchivePayloadStore`: crash-safe staging inside the unison dir.
///
/// - `beginIntent` creates a unique per-operation quarantine directory on the
///   SAME filesystem as the active archives and writes a durable INTENT manifest
///   (temp + fsync + atomic rename + directory fsync) BEFORE any lock is acquired,
///   so even a crash mid-acquisition is detectable on restart (SF1).
/// - `recordPlan` durably rewrites the manifest with the under-lock payload plan
///   (acquiring → staging) before any move.
/// - `stage` moves one payload with a real `rename(2)` (guaranteed atomic on the
///   same filesystem — not `FileManager.moveItem`, which may copy+unlink).
/// - `rollback` renames every staged file back but does NOT remove the record.
/// - `discardRecord` removes the quarantine dir + manifest — called only after
///   every owned lock is confirmed released, so a lock is never orphaned.
/// - `markCommitted` durably marks the manifest committed; `trashQuarantine`
///   moves the ENTIRE quarantine directory to Trash as one unit; on Trash failure
///   it RETAINS the complete quarantine dir and throws (never restores after commit).
final class POSIXStagingStore: ArchivePayloadStore {

    private let activeDir: String
    private let fm: FileManager
    private var manifest: StagingManifest?
    private var stagedNames: [String] = []
    private(set) var quarantinePath: String?

    init(unisonDir: String, fileManager: FileManager = .default) {
        self.activeDir = unisonDir
        self.fm = fileManager
    }

    // MARK: phase 0 — quarantine dir + durable INTENT manifest (before locks)

    func beginIntent(_ manifest: StagingManifest) throws {
        let name = AbandonedStagingScan.quarantinePrefix + UUID().uuidString
        let dir = (activeDir as NSString).appendingPathComponent(name)
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            throw ArchiveStoreError.createQuarantineFailed(errnoOr(error))
        }
        self.quarantinePath = dir
        self.manifest = manifest
        try writeManifestDurably(manifest, inQuarantine: dir)
    }

    // MARK: phase 1 — record the under-lock payload plan (acquiring → staging)

    func recordPlan(_ manifest: StagingManifest) throws {
        guard let q = quarantinePath else { throw ArchiveStoreError.notStaging }
        try writeManifestDurably(manifest, inQuarantine: q)
        self.manifest = manifest
    }

    // MARK: phase 2 — rename(2) each payload in

    func stage(_ name: String) throws {
        guard let q = quarantinePath else { throw ArchiveStoreError.notStaging }
        let src = (activeDir as NSString).appendingPathComponent(name)
        let dst = (q as NSString).appendingPathComponent(name)
        let rc = src.withCString { s in dst.withCString { d in rename(s, d) } }
        if rc != 0 { throw ArchiveStoreError.renameFailed(name: name, errno: errno) }
        stagedNames.append(name)
    }

    // MARK: phase 3 — rollback restores every staged file (record NOT removed)

    func rollback() throws {
        guard let q = quarantinePath else { return }
        // Attempt to restore every staged file. Track which ones could NOT be
        // restored — they remain in the quarantine, never deleted.
        var unrestored: [String] = []
        for name in stagedNames.reversed() {
            let src = (q as NSString).appendingPathComponent(name)
            let dst = (activeDir as NSString).appendingPathComponent(name)
            let rc = src.withCString { s in dst.withCString { d in rename(s, d) } }
            if rc != 0 { unrestored.append(name) }
        }
        if !unrestored.isEmpty {
            // Incomplete: RETAIN the quarantine + manifest (still pre-commit, so
            // restart detection fails closed) and keep only the un-restored
            // names tracked. Do NOT remove anything. Caller keeps the locks held.
            stagedNames = unrestored
            throw ArchiveStoreError.rollbackIncomplete(q)
        }
        stagedNames.removeAll()
        // NOTE: the record is deliberately NOT removed here — removal is gated on
        // confirmed lock release via `discardRecord` (SF1), so an owned lock is
        // never left without a durable recovery record.
    }

    /// Remove the quarantine dir + manifest. The caller has confirmed every owned
    /// lock is released and the payloads are restored/absent.
    func discardRecord() throws {
        guard let q = quarantinePath else { return }
        try? fm.removeItem(atPath: q)
        quarantinePath = nil
        manifest = nil
        stagedNames.removeAll()
    }

    // MARK: phase 4+5 — mark committed, then whole-dir Trash (retain on failure)

    func markCommitted() throws {
        guard let q = quarantinePath, var m = manifest else { throw ArchiveStoreError.notStaging }
        // Durably flip the manifest to committed — the logical commit point. The
        // caller releases the locks (confirmed) BEFORE trashing, so a committed
        // record is never retired while a lock might survive.
        m.phase = StagingManifest.phaseCommitted
        try writeManifestDurably(m, inQuarantine: q)
        self.manifest = m
    }

    func trashQuarantine() throws {
        guard let q = quarantinePath else { return }
        do {
            var out: NSURL?
            try fm.trashItem(at: URL(fileURLWithPath: q), resultingItemURL: &out)
        } catch {
            // Retain the complete quarantine dir; report via quarantinePath.
            throw ArchiveStoreError.trashFailed(q)
        }
        quarantinePath = nil
        manifest = nil
        stagedNames.removeAll()
    }

    // MARK: durable manifest write (temp + fsync + atomic rename + dir fsync)

    private func writeManifestDurably(_ m: StagingManifest, inQuarantine dir: String) throws {
        let data = try JSONEncoder().encode(m)
        let finalPath = (dir as NSString).appendingPathComponent(AbandonedStagingScan.manifestName)
        let tmpPath = finalPath + ".tmp"

        let fd = tmpPath.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o600) }
        guard fd >= 0 else { throw ArchiveStoreError.manifestWriteFailed(errno) }
        var wrote = true
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress!.advanced(by: off), buf.count - off)
                if n <= 0 { wrote = false; break }
                off += n
            }
        }
        if wrote { wrote = (fsync(fd) == 0) }
        close(fd)
        guard wrote else {
            _ = tmpPath.withCString { unlink($0) }
            throw ArchiveStoreError.manifestWriteFailed(errno)
        }
        let rc = tmpPath.withCString { s in finalPath.withCString { d in rename(s, d) } }
        guard rc == 0 else {
            _ = tmpPath.withCString { unlink($0) }
            throw ArchiveStoreError.manifestWriteFailed(errno)
        }
        // Persist the directory entry too (best-effort).
        let dfd = dir.withCString { open($0, O_RDONLY) }
        if dfd >= 0 { _ = fsync(dfd); close(dfd) }
    }

    private func errnoOr(_ error: Error) -> Int32 {
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           u.domain == NSPOSIXErrorDomain { return Int32(u.code) }
        return errno
    }
}
