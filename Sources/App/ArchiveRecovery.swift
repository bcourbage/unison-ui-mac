import Foundation

/// Parses Unison's "archive inconsistency" fatal message and figures out
/// which archive files can be cleaned up locally to recover.
///
/// The message looks like:
///
///     Warning: inconsistent state.
///     The archive file is missing on some hosts.
///     For safety, the remaining copies should be deleted.
///     Archive ar946bfb...  on host Heracles.local should be DELETED
///     Archive ar2e827e...  on host Demeter.local should be DELETED
///     Archive ar4f2... on host Heracles.local is MISSING
///     Please delete archive files as appropriate and try again
///     or invoke Unison with -ignorearchives flag.
///
/// We can't reach the remote host's filesystem from here, but any archive
/// named in the "should be DELETED" list that we can find in the local
/// Unison directory IS deletable from this app. We collect those (plus
/// their matching `fp...` and `lk...` files) and present them to the user.
struct ArchiveRecovery {

    let unisonDirectory: String
    /// Archive name → URLs for ar/fp/lk files that exist locally. Indexed by
    /// the archive's hash suffix so we can produce a stable summary.
    let localOrphans: [URL]
    /// Archive names mentioned as "should be DELETED" that aren't present
    /// locally — the user has to clean these up on the remote host
    /// themselves. We surface these in the alert text.
    let remoteOnlyOrphans: [String]

    var hasLocalOrphans: Bool { !localOrphans.isEmpty }

    static func parse(message: String, unisonDirectory: String) -> ArchiveRecovery? {
        // Only worth parsing when the message looks like an archive-consistency
        // failure. Cheap pre-filter.
        guard message.contains("Archive") && message.contains("should be DELETED") else {
            return nil
        }

        // Matches "Archive arXYZ on host SOMETHING should be DELETED".
        // - Capture group 1: archive base name including the "ar" prefix.
        // - Capture group 2: host string (unused — we decide local/remote by
        //   filesystem presence, not by parsing the hostname).
        let pattern = #"Archive\s+(ar[0-9a-fA-F]+)\s+on host\s+(\S+)\s+should be DELETED"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let fm = FileManager.default
        var locals: [URL] = []
        var remotes: [String] = []

        let nsMsg = message as NSString
        let matches = regex.matches(in: message,
                                    range: NSRange(location: 0, length: nsMsg.length))
        for m in matches where m.numberOfRanges >= 2 {
            let archiveName = nsMsg.substring(with: m.range(at: 1))
            // ar/fp/lk share the same suffix (hash); we strip "ar" from the
            // archive name and rebuild the three companion paths.
            let suffix = String(archiveName.dropFirst(2))
            let candidates = ["ar", "fp", "lk"].map { prefix in
                URL(fileURLWithPath: "\(unisonDirectory)/\(prefix)\(suffix)")
            }

            let presentLocally = candidates.filter { fm.fileExists(atPath: $0.path) }
            if presentLocally.isEmpty {
                remotes.append(archiveName)
            } else {
                locals.append(contentsOf: presentLocally)
            }
        }

        if locals.isEmpty && remotes.isEmpty { return nil }
        return ArchiveRecovery(unisonDirectory: unisonDirectory,
                               localOrphans: locals,
                               remoteOnlyOrphans: remotes)
    }

    /// Delete every local orphan file. Returns the paths that actually went
    /// away (best effort; failures are logged but don't stop the run).
    @discardableResult
    func deleteLocalOrphans() -> [String] {
        var deleted: [String] = []
        for url in localOrphans {
            do {
                try FileManager.default.removeItem(at: url)
                deleted.append(url.path)
            } catch {
                TraceLog.shared.write("ArchiveRecovery: failed to delete \(url.path): \(error)")
            }
        }
        return deleted
    }
}
