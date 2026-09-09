import Foundation

// The record of which startup file this account owns a block in, and the
// classification of a write's outcome. See docs/command-line-setup-design.md,
// "Ownership record".
//
// Two slots per account, `confirmed` and `pending`, each naming the file's
// resolved path, the block's hash, the bundle path written, and a date. A block
// is owned when its hash equals `confirmed` or `pending` for the same resolved
// path. The record is keyed by resolved path, not inode, so an editor's
// replace-save keeps ownership; a user edit inside the block, or loss of
// defaults, makes the block foreign.

/// One ownership slot.
struct CommandLineSetupOwnership: Codable, Equatable {
    /// The startup file's resolved path (symlinks followed).
    let path: String
    /// SHA256 of the block's exact text (CommandLineSetupBlock.hash).
    let hash: String
    /// The bundle `bin` directory the block was written with.
    let bundlePath: String
    let date: Date
}

/// Whether a rename changed the file. Decided from the rename's result and errno.
enum CommandLineSetupMutation: Equatable {
    /// The failure happened before the rename, or the rename failed with an errno
    /// that guarantees no change. Safe to delete `pending`.
    case notMutated
    /// The rename returned success. Keep `pending` until read-back promotes it.
    case mutated
    /// The rename failed with an errno outside the no-change list. Keep `pending`;
    /// the app does not claim the entry was written.
    case uncertain
}

enum CommandLineSetupRecordStore {

    static let confirmedKey = "commandLine.ownership.confirmed"
    static let pendingKey = "commandLine.ownership.pending"

    // MARK: Read

    static func confirmed(defaults: UserDefaults = .standard) -> CommandLineSetupOwnership? {
        decode(defaults.data(forKey: confirmedKey))
    }

    static func pending(defaults: UserDefaults = .standard) -> CommandLineSetupOwnership? {
        decode(defaults.data(forKey: pendingKey))
    }

    /// Whether a block of `hash` in the file resolved to `path` is owned by this
    /// account: its hash matches `confirmed` or `pending` for the same path.
    static func isOwned(path: String, blockHash hash: String,
                        defaults: UserDefaults = .standard) -> Bool {
        for slot in [confirmed(defaults: defaults), pending(defaults: defaults)] {
            if let slot, slot.path == path, slot.hash == hash { return true }
        }
        return false
    }

    // MARK: Write

    /// Record a `pending` slot for a new or rewritten block, leaving `confirmed`
    /// untouched. Returns false when defaults could not store it, in which case
    /// the caller must refuse before touching the file.
    @discardableResult
    static func writePending(_ record: CommandLineSetupOwnership,
                             defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        defaults.set(data, forKey: pendingKey)
        // Read back through the same store: a failure to persist must be caught
        // here, not discovered after the file is changed.
        return pending(defaults: defaults) == record
    }

    /// Promote `pending` to `confirmed` after a successful read-back, clearing
    /// `pending`.
    static func promote(defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: pendingKey) else { return }
        defaults.set(data, forKey: confirmedKey)
        defaults.removeObject(forKey: pendingKey)
    }

    static func deletePending(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingKey)
    }

    /// Delete both slots, on a successful removal.
    static func deleteBoth(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: confirmedKey)
        defaults.removeObject(forKey: pendingKey)
    }

    // MARK: Outcome classification

    /// The errnos from `rename(2)` that guarantee the target was not changed.
    /// Verified against both `renameat` and `renameatx_np` with `RENAME_EXCL` at
    /// implementation review. Anything outside this list is uncertain, not absence.
    static let noChangeErrnos: Set<Int32> = [ENOENT, EACCES, EPERM, EEXIST, ENOTDIR, EXDEV]

    static func classify(renameSucceeded: Bool, errnoValue: Int32) -> CommandLineSetupMutation {
        if renameSucceeded { return .mutated }
        return noChangeErrnos.contains(errnoValue) ? .notMutated : .uncertain
    }

    // MARK: Helpers

    private static func decode(_ data: Data?) -> CommandLineSetupOwnership? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(CommandLineSetupOwnership.self, from: data)
    }
}
