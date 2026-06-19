import Foundation
import AppKit

/// Swift-side façade around the C bridge to OCaml.
///
/// Today this only handles the `displayStatus` callback. As we replace more
/// of the abort-stubbed callbacks in UnisonBridgeC.c, the handlers list will
/// grow — keep them registered through a single chokepoint so we have one
/// place to reason about thread-safety and lifetime.
enum UnisonBridge {

    /// Closure invoked when OCaml calls the `displayStatus` callback.
    /// Called on whatever thread OCaml is on — handlers that touch UI must
    /// dispatch to the main thread themselves (this becomes worth automating
    /// once we have a real GUI).
    ///
    /// `nonisolated(unsafe)` because installation happens once at startup
    /// before the OCaml thread can call in; concurrent reads of a stable
    /// reference are safe. Revisit if we add re-registration at runtime.
    nonisolated(unsafe) static var statusHandler: ((String) -> Void)?
    nonisolated(unsafe) static var progressHandler: ((Double) -> Void)?
    nonisolated(unsafe) static var init1CompleteHandler: ((Bool) -> Void)?
    nonisolated(unsafe) static var init2CompleteHandler: (([StateItem]) -> Void)?
    nonisolated(unsafe) static var reloadRowHandler: ((_ row: Int, _ progress: String, _ bytes: Int64) -> Void)?
    nonisolated(unsafe) static var syncCompleteHandler: (() -> Void)?

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

    static func installReloadRowHandler(_ handler: @escaping (Int, String, Int64) -> Void) {
        reloadRowHandler = handler
        unison_bridge_set_reload_row_handler(_swiftReloadRowTrampoline)
    }

    static func installSyncCompleteHandler(_ handler: @escaping () -> Void) {
        syncCompleteHandler = handler
        unison_bridge_set_sync_complete_handler(_swiftSyncCompleteTrampoline)
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

/* Called synchronously on the OCaml thread; the bridge frees the C array
 * after we return, so we must convert every string before async-dispatching. */
private func _swiftInit2CompleteTrampoline(
    items: UnsafePointer<unison_state_item_t>?, count: Int
) {
    var converted: [StateItem] = []
    if let items, count > 0 {
        converted.reserveCapacity(count)
        for i in 0..<count {
            let ci = items[i]
            converted.append(StateItem(
                path:             ci.path.map { String(cString: $0) } ?? "",
                left:             ci.left.map { String(cString: $0) } ?? "",
                right:            ci.right.map { String(cString: $0) } ?? "",
                direction:        ci.direction.map { String(cString: $0) } ?? "",
                sizeBytes:        ci.size_bytes,
                fileType:         ci.file_type.map { String(cString: $0) } ?? "",
                progress:         ci.progress.map { String(cString: $0) } ?? "",
                bytesTransferred: ci.bytes_transferred
            ))
        }
    }
    DispatchQueue.main.async {
        UnisonBridge.init2CompleteHandler?(converted)
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

private func _swiftSyncCompleteTrampoline() {
    DispatchQueue.main.async {
        UnisonBridge.syncCompleteHandler?()
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
        let userWantsExit = (response == .alertSecondButtonReturn)
        // Wake the OCaml worker first so it can continue (or exit) promptly,
        // then notify the app so it can reset UI state if the user cancelled.
        unison_bridge_warn_response(UnsafeMutableRawPointer(bitPattern: opaqueBits), userWantsExit)
        UnisonBridge.warnDismissedHandler?(text, userWantsExit)
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
                let deleted = recovery.deleteLocalOrphans()
                TraceLog.shared.write("ArchiveRecovery: deleted \(deleted.count) file(s):")
                for p in deleted { TraceLog.shared.write("  \(p)") }
                shouldRetry = true
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
