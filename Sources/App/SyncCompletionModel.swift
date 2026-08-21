import Foundation

/// Pure, completion-time application of the post-sync snapshot (Finding #10).
///
/// Replaces the old per-row `unison_bridge_ri_get_details` bridge loop in
/// `finalizeSyncUI` with cached data from the single bulk snapshot — so the
/// completion path makes ZERO per-row bridge calls (by construction: this type
/// touches only the passed-in arrays). It preserves the EXACT prior
/// details-based failure attribution — a row whose final progress isn't already
/// a failure but whose details carry a failure marker is synthesized to
/// `FAILED: <reason>` — so transfer failures and partial/problematic rows are
/// attributed identically to before.
enum SyncCompletionModel {

    struct Applied: Equatable {
        /// Rows with final progress + synthesized failures applied.
        let items: [StateItem]
        /// Indices whose final progress parses as a failure.
        let failedRows: Set<Int>
    }

    enum Outcome: Equatable {
        case applied(Applied)
        /// The snapshot's row count didn't match the current row set. The
        /// caller must route to the unavailable-results path and apply NOTHING
        /// (never a partial snapshot).
        case countMismatch(expected: Int, got: Int)
    }

    static func apply(
        snapshot: [SyncSnapshotRow],
        to items: [StateItem],
        detailsIndicateFailure: (String) -> Bool = ReconcileWindowController.detailsIndicateFailure,
        failureReason: (String) -> String = ReconcileWindowController.failureReason
    ) -> Outcome {
        guard snapshot.count == items.count else {
            return .countMismatch(expected: items.count, got: snapshot.count)
        }
        var out = items
        for i in out.indices {
            let snap = snapshot[i]
            var progress = snap.progress
            // Same synthesis the old completion pass did — only now the details
            // come from the cached snapshot, not a per-row bridge round-trip.
            if !ProgressDescriptor.parse(progress).isFailure,
               detailsIndicateFailure(snap.details) {
                progress = "FAILED: \(failureReason(snap.details))"
            }
            out[i] = out[i].with(progress: progress, bytesTransferred: snap.bytesTransferred)
        }
        let failed = Set(out.indices.filter {
            ProgressDescriptor.parse(out[$0].progress).isFailure
        })
        return .applied(Applied(items: out, failedRows: failed))
    }
}
