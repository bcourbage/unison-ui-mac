import CryptoKit
import Foundation

/// The configuration a remote check was started against, reduced to one
/// digest. A completion is accepted only when the token recomputed at that
/// moment, from the form's current values and a fresh resolution, equals the
/// token taken at the start; otherwise the result describes settings that are
/// no longer effective and is discarded.
///
/// Covered: the form's roots, Remote unison, SSH command, SSH args and
/// `addversionno` as effective values; the editor session; and, for every
/// path that took part in resolution, present or absent, its existence and,
/// when present, its identity (device, inode), size, modification time and
/// content hash. An optional include that appears, or an exact-name lookup
/// candidate that appears beside an unchanged `.prf`, changes the token.
struct RemoteCheckToken: Equatable {

    /// The form values that participate.
    struct FormValues: Equatable {
        var roots: [String]
        var servercmd: String
        var sshcmd: String
        var sshargs: String
        var addversionno: Bool
    }

    let digest: String

    /// Per-path identity for a present dependency.
    struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: UInt64
        let modificationNanoseconds: UInt64
        let contentHash: String
    }

    /// Reads the identity of a present dependency; nil when it cannot be read,
    /// which is folded into the token as its own state.
    static func filesystemIdentity(_ path: String) -> FileIdentity? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let mtime = UInt64(st.st_mtimespec.tv_sec) &* 1_000_000_000 &+ UInt64(st.st_mtimespec.tv_nsec)
        return FileIdentity(device: UInt64(st.st_dev), inode: UInt64(st.st_ino),
                            size: UInt64(st.st_size), modificationNanoseconds: mtime, contentHash: hash)
    }

    static func make(form: FormValues,
                     effective: EffectiveProfile,
                     sessionID: UUID,
                     identity: (String) -> FileIdentity? = RemoteCheckToken.filesystemIdentity) -> RemoteCheckToken {
        var lines: [String] = []
        lines.append("session=\(sessionID.uuidString)")
        lines.append("roots=" + form.roots.joined(separator: "\u{1F}"))
        lines.append("servercmd=\(form.servercmd)")
        lines.append("sshcmd=\(form.sshcmd)")
        lines.append("sshargs=\(form.sshargs)")
        lines.append("addversionno=\(form.addversionno)")
        for d in effective.dependencies.sorted(by: { $0.path < $1.path }) {
            if d.present, let id = identity(d.path) {
                lines.append("present \(d.path) \(id.device):\(id.inode) \(id.size) \(id.modificationNanoseconds) \(id.contentHash)")
            } else if d.present {
                lines.append("present-unreadable \(d.path)")
            } else {
                lines.append("absent \(d.path)")
            }
        }
        let joined = lines.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
        return RemoteCheckToken(digest: hash)
    }
}
