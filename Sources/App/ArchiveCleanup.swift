import Foundation

/// Indexes and identifies the local archive files for a given hash. Used to
/// discover the payload a mutation will act on (Reset Archives, Clean Stale,
/// delete-with-archives). This type only READS the Unison directory; the actual
/// destructive mutation runs through the crash-safe `ArchiveMutation`
/// transaction via `ArchiveMaintenance` (see the NOTE at the end of the file).
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
/// `archiveVersion`. The crash-only variants are included on purpose: if the
/// user is resetting archives, something went wrong and a clean slate is wanted.
struct ArchiveCleanup {

    /// The archive PAYLOAD prefixes. `lk` is deliberately EXCLUDED (Blocker
    /// B3): it is the interprocess lock, not payload — the mutation transaction
    /// acquires and holds it across the operation, and it must never appear in a
    /// file list to be mutated (removing a live lock removes Unison's exclusion).
    /// Matches `ArchiveMutationPlan.payloadPrefixes`.
    static let archivePrefixes = ["ar", "fp", "tm", "sc"]

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

    /// One indexed local archive (`ar<hash>`) together with the roots
    /// Unison recorded in its header. This lets callers match archives
    /// to a profile by reading what Unison actually wrote, rather than
    /// recomputing a hash — which can't be derived offline for ssh roots
    /// (the remote hostname + resolved path are only known after a
    /// connection). See `ArchiveHash.MultiResult.allRootsLocal`.
    struct ArchiveEntry: Equatable {
        let url: URL
        /// Filename suffix after the `ar` prefix; shared by siblings.
        let hash: String
        /// `//host//path` of the local replica this archive is "for".
        let thisRoot: String
        /// Sorted, comma-joined canonical roots (both replicas).
        let rootsName: String
    }

    /// A parsed Unison archive header.
    struct ParsedHeader: Equatable {
        /// Archive format from the `Unison archive format N` line.
        let format: Int
        let thisRoot: String
        let rootsName: String
    }

    /// Scan the Unison directory for `ar*` files, parse each header, and
    /// return only the **authentic** archives — those whose filename hash
    /// equals `MD5(thisRoot;rootsName;format)` recomputed from their own
    /// header. Unison names every archive that way, so a mismatch means
    /// the file is corrupt, hand-renamed, or not a Unison archive at all;
    /// we exclude it so it is never matched to a profile or trashed. Files
    /// whose header doesn't parse are skipped the same way.
    func indexArchives() -> [ArchiveEntry] {
        let fm = FileManager.default
        let baseDir = URL(fileURLWithPath: unisonDirectory)
        guard let names = try? fm.contentsOfDirectory(atPath: unisonDirectory) else {
            return []
        }
        var entries: [ArchiveEntry] = []
        for name in names where name.hasPrefix("ar") {
            let url = baseDir.appendingPathComponent(name)
            guard let header = Self.parseArchiveHeader(at: url) else { continue }
            let hash = String(name.dropFirst(2))
            let expected = ArchiveHash.md5Hex(
                "\(header.thisRoot);\(header.rootsName);\(header.format)")
            guard expected == hash else {
                TraceLog.shared.write(
                    "ArchiveCleanup: skipping '\(name)' — header hash \(expected) " +
                    "doesn't match filename (not an authentic archive)")
                continue
            }
            entries.append(ArchiveEntry(url: url,
                                        hash: hash,
                                        thisRoot: header.thisRoot,
                                        rootsName: header.rootsName))
        }
        return entries
    }

    /// Parse a Unison archive's first two header lines:
    ///   `Unison archive format <N>`
    ///   `Archive for root <thisRoot> synchronizing roots <rootsName>`
    /// Only the first kilobyte is read (the header is tiny and precedes
    /// the binary body). Lenient UTF-8 decoding is deliberate: the body
    /// bytes after the header aren't valid UTF-8, but the ASCII header
    /// lines survive intact, so we never reject a real archive.
    static func parseArchiveHeader(at url: URL) -> ParsedHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 1024)) ?? Data()
        guard !data.isEmpty else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        let formatMarker = "Unison archive format "
        let rootMarker = "Archive for root "
        let separator = " synchronizing roots "
        var format: Int?
        var thisRoot: String?
        var rootsName: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.hasPrefix(formatMarker) {
                format = Int(line.dropFirst(formatMarker.count)
                    .trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix(rootMarker), let r = line.range(of: separator) {
                thisRoot = String(line[line.index(line.startIndex,
                    offsetBy: rootMarker.count)..<r.lowerBound])
                rootsName = String(line[r.upperBound...])
            }
            if let format, let thisRoot, let rootsName {
                return ParsedHeader(format: format, thisRoot: thisRoot, rootsName: rootsName)
            }
        }
        return nil
    }

    // NOTE: there is deliberately NO `trash(_:)` here. Destructive archive
    // mutation has a single authority — the crash-safe ArchiveMutation
    // transaction via ArchiveMaintenance (acquire lock → stage → whole-dir
    // Trash). `ArchiveCleanup` only INDEXES/finds archives; it never mutates.
}
