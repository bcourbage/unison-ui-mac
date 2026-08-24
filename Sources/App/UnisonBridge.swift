import Foundation
import AppKit

/// One row of the post-sync completion snapshot (Finding #10), copied out of the
/// C `unison_sync_row_t` before the bridge frees it. Carries each row's final
/// progress + details + bytes so `finalizeSyncUI` needs ZERO per-row bridge
/// calls at completion.
struct SyncSnapshotRow: Sendable, Equatable {
    let progress: String
    let details: String
    let bytesTransferred: Int64
}

/// Swift-side façade around the C bridge to OCaml. All OCaml callbacks are
/// registered through this single chokepoint. Each trampoline (below) copies
/// any C-owned payload off OCaml's pointers and delivers the handler on the
/// main queue, so handlers are free to touch UI inline — they never run on an
/// arbitrary OCaml worker thread.
enum UnisonBridge {

    /// Closure invoked when OCaml calls the `displayStatus` callback. Delivered
    /// on the main queue by `_swiftStatusTrampoline` (which copies the C string
    /// first), so it is safe to touch UI directly.
    ///
    /// `nonisolated(unsafe)` because installation happens once at startup
    /// before the OCaml thread can call in; concurrent reads of a stable
    /// reference are safe. Revisit if we add re-registration at runtime.
    nonisolated(unsafe) static var statusHandler: ((String) -> Void)?
    nonisolated(unsafe) static var progressHandler: ((Double) -> Void)?
    nonisolated(unsafe) static var init1CompleteHandler: ((Bool) -> Void)?
    nonisolated(unsafe) static var init2CompleteHandler: (([StateItem]) -> Void)?
    /// Fires (main queue) when a scan completes in OCaml but its state could not
    /// be published (Blocker 2) — the terminal alternative to
    /// `init2CompleteHandler`. Routes to `operationFailed(engineIsQuiescent:
    /// false)` so a stranded `.scanning` becomes restart-required.
    nonisolated(unsafe) static var scanFailedHandler: (() -> Void)?
    /// Fires (main queue) when a successful Ignore produces a fresh row set.
    /// DISTINCT from `init2CompleteHandler` so an Ignore completion never
    /// satisfies/clears a pending scan. The driver binds it to the exact session
    /// that invoked the Ignore.
    nonisolated(unsafe) static var ignoreCompleteHandler: (([StateItem]) -> Void)?
    nonisolated(unsafe) static var reloadRowHandler: ((_ row: Int, _ progress: String, _ bytes: Int64) -> Void)?
    /// Fires (main queue) when sync + archive commit complete. `ok == true`
    /// delivers the full per-row completion snapshot; `ok == false` means the
    /// snapshot couldn't be marshalled (results unavailable — never partial).
    nonisolated(unsafe) static var syncCompleteHandler: ((_ ok: Bool, _ rows: [SyncSnapshotRow]) -> Void)?

    /// Fires when OCaml's `displayDiff` callback completes. `title` is
    /// the file's relative path; `text` is the diff output (typically
    /// unified-diff format from `diff -u`). Invoked on the main queue
    /// AFTER the trampoline has copied both strings off OCaml's
    /// pointers.
    nonisolated(unsafe) static var diffHandler: ((_ title: String, _ text: String) -> Void)?

    /// Fires when OCaml's `displayDiffErr` callback fires. The handler
    /// usually routes this into the active DiffWindow's error display.
    /// Also mirrored to the status log via the C bridge for diagnosis.
    nonisolated(unsafe) static var diffErrHandler: ((_ msg: String) -> Void)?

    /// Called on the main queue *after* the warning sheet is dismissed.
    /// `cancelled = true` means the user chose "Cancel sync" — OCaml will
    /// typically exit the process; nothing more to do. `cancelled = false`
    /// means "Proceed" — OCaml continues; UI stays in its busy state.
    nonisolated(unsafe) static var warnDismissedHandler: ((_ msg: String, _ cancelled: Bool) -> Void)?

    /// Called on the main queue after the fatal-error sheet is dismissed.
    /// At this point OCaml's worker thread is unwinding — any in-flight
    /// init1/init2/sync will NOT fire its complete callback. The Swift UI
    /// needs to reset its busy state itself.
    ///
    /// `shouldRetry` is true when the modal offered a recovery action
    /// (e.g. "Delete orphan archives and retry") AND the user chose it. In
    /// that case the caller is expected to re-trigger the in-flight
    /// operation (typically by calling `profileSelected` again).
    nonisolated(unsafe) static var fatalDismissedHandler: ((_ msg: String, _ shouldRetry: Bool) -> Void)?

    /// Invoked (main queue) when the user picks "Retry Ignoring Archives"
    /// on an archive-inconsistency fatal. The handler is expected to close
    /// the broken reconcile state and re-run the profile with a one-shot
    /// `ignorearchives` override. Distinct from `fatalDismissedHandler` so
    /// the existing dismiss / delete-orphans-and-retry paths are untouched.
    nonisolated(unsafe) static var fatalRetryIgnoreArchivesHandler: (() -> Void)?

    /// Override hook for tests / autotest. When set, the fatal trampoline
    /// consults this for the path to the local Unison directory used by
    /// `ArchiveRecovery`. Production code reads it from
    /// `unison_bridge_unison_directory()`.
    nonisolated(unsafe) static var unisonDirectoryOverride: String?

    static func installStatusHandler(_ handler: @escaping (String) -> Void) {
        statusHandler = handler
        unison_bridge_set_status_handler(_swiftStatusTrampoline)
    }

    static func installProgressHandler(_ handler: @escaping (Double) -> Void) {
        progressHandler = handler
        unison_bridge_set_progress_handler(_swiftProgressTrampoline)
    }

    static func installInit1CompleteHandler(_ handler: @escaping (Bool) -> Void) {
        init1CompleteHandler = handler
        unison_bridge_set_init1_complete_handler(_swiftInit1CompleteTrampoline)
    }

    static func installInit2CompleteHandler(_ handler: @escaping ([StateItem]) -> Void) {
        init2CompleteHandler = handler
        unison_bridge_set_init2_complete_handler(_swiftInit2CompleteTrampoline)
    }

    static func installScanFailedHandler(_ handler: @escaping () -> Void) {
        scanFailedHandler = handler
        unison_bridge_set_scan_failed_handler(_swiftScanFailedTrampoline)
    }

    static func installIgnoreCompleteHandler(_ handler: @escaping ([StateItem]) -> Void) {
        ignoreCompleteHandler = handler
        unison_bridge_set_ignore_complete_handler(_swiftIgnoreCompleteTrampoline)
    }

    static func installReloadRowHandler(_ handler: @escaping (Int, String, Int64) -> Void) {
        reloadRowHandler = handler
        unison_bridge_set_reload_row_handler(_swiftReloadRowTrampoline)
    }

    static func installSyncCompleteHandler(_ handler: @escaping (Bool, [SyncSnapshotRow]) -> Void) {
        syncCompleteHandler = handler
        unison_bridge_set_sync_complete_handler(_swiftSyncCompleteTrampoline)
    }

    /// Convert a C completion payload into `(ok, rows)`, rejecting malformed
    /// success shapes rather than treating them as an empty successful snapshot:
    /// a negative count, or a positive count with a null `rows` pointer, means
    /// the results are actually unavailable (`ok=false`). Internal so it can be
    /// unit-tested directly (the trampoline is otherwise a private thunk).
    static func convertSyncCompletion(
        ok: Bool, count: Int32, rows: UnsafePointer<unison_sync_row_t>?
    ) -> (ok: Bool, rows: [SyncSnapshotRow]) {
        guard ok else { return (false, []) }
        if count < 0 || (count > 0 && rows == nil) { return (false, []) }
        var converted: [SyncSnapshotRow] = []
        if let rows, count > 0 {
            converted.reserveCapacity(Int(count))
            for i in 0..<Int(count) {
                let r = rows[i]
                converted.append(SyncSnapshotRow(
                    progress: r.progress.map { String(cString: $0) } ?? "",
                    details: r.details.map { String(cString: $0) } ?? "",
                    bytesTransferred: r.bytes_transferred))
            }
        }
        return (true, converted)
    }

    static func installDiffHandler(_ handler: @escaping (String, String) -> Void) {
        diffHandler = handler
        unison_bridge_set_diff_handler(_swiftDiffTrampoline)
    }

    static func installDiffErrHandler(_ handler: @escaping (String) -> Void) {
        diffErrHandler = handler
        unison_bridge_set_diff_err_handler(_swiftDiffErrTrampoline)
    }

    /// Install the warning sheet handler. The OCaml thread blocks until the
    /// user dismisses. After dismissal (on the main queue) we invoke
    /// `onDismiss(msg, userCancelled)` — handler is responsible for any UI
    /// reset (e.g. clearing busy state if the user cancelled sync).
    static func installWarnHandler(onDismiss: @escaping (String, Bool) -> Void) {
        warnDismissedHandler = onDismiss
        unison_bridge_set_warn_handler(_swiftWarnTrampoline)
    }

    /// Install the fatal-error sheet handler. After the user dismisses the
    /// modal, `onDismiss(msg, shouldRetry)` is called on the main queue.
    /// OCaml's worker thread is unwinding past the failure point, so the
    /// caller is responsible for resetting any in-flight UI state, and —
    /// when shouldRetry is true — for re-triggering the operation.
    static func installFatalHandler(onDismiss: @escaping (String, Bool) -> Void) {
        fatalDismissedHandler = onDismiss
        unison_bridge_set_fatal_handler(_swiftFatalTrampoline)
    }
}

/* Trampolines: called from the OCaml worker thread. Hop to the main queue
 * before invoking user handlers so UI code is safe to write inline. */

private func _swiftStatusTrampoline(cstr: UnsafePointer<CChar>?) {
    guard let cstr else { return }
    let s = String(cString: cstr)
    DispatchQueue.main.async {
        UnisonBridge.statusHandler?(s)
    }
}

private func _swiftProgressTrampoline(fraction: Double) {
    DispatchQueue.main.async {
        UnisonBridge.progressHandler?(fraction)
    }
}

private func _swiftInit1CompleteTrampoline(needsPrompt: Bool) {
    DispatchQueue.main.async {
        UnisonBridge.init1CompleteHandler?(needsPrompt)
    }
}

/// Convert the bridge's C row array into `[StateItem]`. MUST be called
/// synchronously on the OCaml thread (before the bridge frees the array).
private func convertStateItems(
    _ items: UnsafePointer<unison_state_item_t>?, _ count: Int
) -> [StateItem] {
    var converted: [StateItem] = []
    if let items, count > 0 {
        converted.reserveCapacity(count)
        for i in 0..<count {
            let ci = items[i]
            converted.append(StateItem(
                path:               ci.path.map { String(cString: $0) } ?? "",
                left:               ci.left.map { String(cString: $0) } ?? "",
                right:              ci.right.map { String(cString: $0) } ?? "",
                direction:          ci.direction.map { String(cString: $0) } ?? "",
                sizeBytes:          ci.size_bytes,
                fileType:           ci.file_type.map { String(cString: $0) } ?? "",
                progress:           ci.progress.map { String(cString: $0) } ?? "",
                bytesTransferred:   ci.bytes_transferred,
                changedFromDefault: ci.changed_from_default
            ))
        }
    }
    return converted
}

/* Called synchronously on the OCaml thread; the bridge frees the C array
 * after we return, so we must convert every string before async-dispatching. */
private func _swiftInit2CompleteTrampoline(
    items: UnsafePointer<unison_state_item_t>?, count: Int
) {
    let converted = convertStateItems(items, count)
    DispatchQueue.main.async {
        UnisonBridge.init2CompleteHandler?(converted)
    }
}

private func _swiftScanFailedTrampoline() {
    DispatchQueue.main.async {
        UnisonBridge.scanFailedHandler?()
    }
}

private func _swiftIgnoreCompleteTrampoline(
    items: UnsafePointer<unison_state_item_t>?, count: Int
) {
    let converted = convertStateItems(items, count)
    DispatchQueue.main.async {
        UnisonBridge.ignoreCompleteHandler?(converted)
    }
}

private func _swiftReloadRowTrampoline(row: Int32, state: UnsafePointer<unison_row_state_t>?) {
    guard let state else { return }
    // Copy the string synchronously — pointer becomes invalid once we return
    // and OCaml proceeds.
    let progress = state.pointee.progress.map { String(cString: $0) } ?? ""
    let bytes = state.pointee.bytes_transferred
    let r = Int(row)
    DispatchQueue.main.async {
        UnisonBridge.reloadRowHandler?(r, progress, bytes)
    }
}

/* Called synchronously on the OCaml thread; the bridge frees the C snapshot
 * array after we return, so we must copy every string before async-dispatching. */
private func _swiftSyncCompleteTrampoline(
    ok: Bool, count: Int32, rows: UnsafePointer<unison_sync_row_t>?
) {
    let (deliverOk, converted) = UnisonBridge.convertSyncCompletion(ok: ok, count: count, rows: rows)
    DispatchQueue.main.async {
        UnisonBridge.syncCompleteHandler?(deliverOk, converted)
    }
}

/// Fires from the OCaml worker thread with (title, text) pointers
/// owned by OCaml's heap. We MUST copy both strings before
/// async-dispatching — pointers become invalid once OCaml proceeds.
private func _swiftDiffTrampoline(title: UnsafePointer<CChar>?,
                                  text: UnsafePointer<CChar>?) {
    let titleStr = title.map { String(cString: $0) } ?? ""
    let textStr = text.map { String(cString: $0) } ?? ""
    DispatchQueue.main.async {
        UnisonBridge.diffHandler?(titleStr, textStr)
    }
}

private func _swiftDiffErrTrampoline(msg: UnsafePointer<CChar>?) {
    let msgStr = msg.map { String(cString: $0) } ?? "<no message>"
    DispatchQueue.main.async {
        UnisonBridge.diffErrHandler?(msgStr)
    }
}

/* The warn/fatal trampolines are called from the OCaml worker thread with
 * the runtime lock released. We dispatch the UI work to main, but the OCaml
 * thread is parked on a condvar inside the C bridge — so we MUST call
 * unison_bridge_{warn,fatal}_response on every path or OCaml deadlocks. */

/* Pass the opaque pointer across the concurrency boundary as an Int —
 * UnsafeMutableRawPointer isn't Sendable but the integer is, and the
 * round-trip via bitPattern is safe since the C side guarantees the
 * memory lives until *_response is called. */

private func _swiftWarnTrampoline(msg: UnsafePointer<CChar>?, opaque: UnsafeMutableRawPointer?) {
    guard let opaque else { return }
    let text = msg.map { String(cString: $0) } ?? "<no message>"
    let opaqueBits = Int(bitPattern: opaque)
    DispatchQueue.main.async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unison warning"
        alert.informativeText = text
        alert.addButton(withTitle: "Proceed")
        alert.addButton(withTitle: "Cancel sync")
        let response = alert.runModal()
        let userCancelled = (response == .alertSecondButtonReturn)
        // NEVER answer the engine "exit". Unison's Cocoa-bridge warn
        // semantics treat exit=true as "quit the program" — it calls
        // exit(), which silently killed the whole app on "Cancel sync"
        // (clean exit, no crash report). Always answer "proceed" (false)
        // so the engine keeps the process alive; if the user cancelled,
        // the handler below aborts the operation and returns to the picker
        // (like Stop). Wake the worker first, then notify the app.
        unison_bridge_warn_response(UnsafeMutableRawPointer(bitPattern: opaqueBits), false)
        UnisonBridge.warnDismissedHandler?(text, userCancelled)
    }
}

private func _swiftFatalTrampoline(msg: UnsafePointer<CChar>?, opaque: UnsafeMutableRawPointer?) {
    guard let opaque else { return }
    let text = msg.map { String(cString: $0) } ?? "<no message>"
    let opaqueBits = Int(bitPattern: opaque)

    // Try to extract a recovery option BEFORE dispatching to main —
    // ArchiveRecovery.parse only touches the filesystem and the message
    // string, so it's safe here. Recovery is offered only when at least
    // one orphan archive file exists locally.
    let unisonDir = UnisonBridge.unisonDirectoryOverride
        ?? unison_bridge_unison_directory().map { String(cString: $0) }
        ?? NSString(string: "~/Library/Application Support/Unison").expandingTildeInPath
    let recovery = ArchiveRecovery.parse(message: text, unisonDirectory: unisonDir)

    DispatchQueue.main.async {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Unison error"
        alert.informativeText = text

        var shouldRetry = false
        var retryIgnoringArchives = false

        if let recovery {
            // Archive inconsistency. "Retry Ignoring Archives" is the
            // robust, always-available recovery (rebuilds Unison's state
            // by comparing the replicas directly) — it's the default
            // (first) button, and the only escape from the case where the
            // missing/extra archive lives on the *remote* host, so there's
            // nothing local to delete. The orphan-delete button is offered
            // additionally only when local orphans actually exist.
            alert.addButton(withTitle: "Retry Ignoring Archives")
            let hasDelete = recovery.hasLocalOrphans
            if hasDelete {
                let count = recovery.localOrphans.filter { $0.lastPathComponent.hasPrefix("ar") }.count
                alert.addButton(withTitle: "Delete \(count) Orphan Archive\(count == 1 ? "" : "s") and Retry")
            }
            alert.addButton(withTitle: "OK")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                retryIgnoringArchives = true
            } else if hasDelete, response == .alertSecondButtonReturn {
                // Route through the single mutation authority: the failed op has
                // already unwound (the embedded engine isn't using these
                // archives), so isEngineIdle is true here; the per-archive lock
                // still blocks an EXTERNAL Unison, and staging keeps the removal
                // atomic (never a partial family, lk never trashed).
                let result = ArchiveMaintenance.mutate(
                    operation: "fatal-recovery",
                    hashes: recovery.localOrphanHashes,
                    unisonDirectory: unisonDir,
                    isEngineIdle: { true },
                    revalidate: { _ in true })
                switch result {
                case .success(let out):
                    TraceLog.shared.write("ArchiveRecovery: removed \(out.hashes.count) archive(s)"
                        + (out.quarantineRetained.map { "; quarantine retained at \($0)" } ?? ""))
                    switch out.disposition {
                    case .clean, .lockFreeLeftover:
                        // Removal succeeded and no lock survives — safe to retry.
                        shouldRetry = true
                    case .blockedByLock:
                        // A lock could not be released: the committed record is
                        // retained and those archives stay blocked. Retrying would
                        // re-enter the same inconsistency — leave it for explicit
                        // recovery on next launch.
                        (NSApp.delegate as? ArchiveBlockCoordinating)?.refreshBlockedArchiveState()
                        TraceLog.shared.write("ArchiveRecovery: lock not released — not retrying")
                        shouldRetry = false
                    }
                case .failure(let error):
                    // A pre-existing lock (another process) blocked it — don't
                    // retry into the same inconsistency; leave it for the user.
                    if CleanStaleArchivesWindowController.mutationRequiresBlockRefresh(error) {
                        // A lock is still held (our abort, a split family, or a
                        // foreign lock) — refresh the in-session block so the
                        // profile is gated immediately.
                        (NSApp.delegate as? ArchiveBlockCoordinating)?.refreshBlockedArchiveState()
                    }
                    TraceLog.shared.write("ArchiveRecovery: mutation refused — \(error)")
                    shouldRetry = false
                }
            }
        } else {
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
        }

        unison_bridge_fatal_response(UnsafeMutableRawPointer(bitPattern: opaqueBits))
        if retryIgnoringArchives {
            UnisonBridge.fatalRetryIgnoreArchivesHandler?()
        } else {
            UnisonBridge.fatalDismissedHandler?(text, shouldRetry)
        }
    }
}
