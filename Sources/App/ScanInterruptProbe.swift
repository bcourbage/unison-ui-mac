import Foundation

/// One in-flight `ssh -G` scan-interruption qualification subprocess (issue #24,
/// Wiring PR). Carries its owning session + connection generation, a
/// lifecycle-owned canceller (SIGTERM→kill→reap), and a `done` semaphore the
/// worker signals AFTER `qualify` (including any teardown) returns — so shutdown
/// can WAIT for the reap.
///
/// `@unchecked Sendable`: every stored member is an immutable `let` and is
/// itself thread-safe (the canceller is lock-guarded, the semaphore is
/// Sendable), so the probe is safe to hand to the qualification worker.
final class ScanInterruptQualProbe: @unchecked Sendable {
    let session: EngineSessionCoordinator.SessionID
    let generation: UInt64
    let canceller = VersionCheck.ProbeCanceller()
    let done = DispatchSemaphore(value: 0)

    init(session: EngineSessionCoordinator.SessionID, generation: UInt64) {
        self.session = session
        self.generation = generation
    }
}

/// Tracks scan-interruption qualification probes with TWO distinct views (round
/// 2 Finding 4 / round 3 correction 2):
///
///  - **current-by-session** — the probe whose result may still be applied for a
///    session (identity/generation logic).
///  - **all-live** — EVERY probe whose subprocess has not yet completed,
///    including ones that were cancelled or SUPERSEDED. A cancelled/superseded
///    probe keeps running its teardown (SIGTERM→kill→reap) after it stops being
///    the current one, so it must stay tracked until completion or shutdown
///    cannot cancel+wait for its reap.
///
/// Main-thread confined (the driver touches it only on the main queue).
final class ScanInterruptProbeRegistry {
    private var currentBySession: [EngineSessionCoordinator.SessionID: ScanInterruptQualProbe] = [:]
    private var live: [ObjectIdentifier: ScanInterruptQualProbe] = [:]

    /// Register a fresh probe as the session's current, SUPERSEDING (and
    /// cancelling) any prior current probe. The superseded probe stays in the
    /// live set until it completes.
    func register(_ probe: ScanInterruptQualProbe) {
        currentBySession[probe.session]?.canceller.cancel()   // supersede
        currentBySession[probe.session] = probe
        live[ObjectIdentifier(probe)] = probe
    }

    /// Cancel the session's current probe (leave / close / skip). It is removed
    /// as current but RETAINED in the live set until its worker completes.
    func cancelCurrent(session: EngineSessionCoordinator.SessionID) {
        currentBySession[session]?.canceller.cancel()
        currentBySession[session] = nil
    }

    /// A probe's subprocess finished: drop it from the live set, and clear it as
    /// current iff it is still the current one (a superseded probe completing
    /// must NOT disturb its successor).
    func complete(_ probe: ScanInterruptQualProbe) {
        live[ObjectIdentifier(probe)] = nil
        if currentBySession[probe.session] === probe {
            currentBySession[probe.session] = nil
        }
    }

    /// True iff `probe` is still the current probe for its session.
    func isCurrent(_ probe: ScanInterruptQualProbe) -> Bool {
        currentBySession[probe.session] === probe
    }

    /// Every probe whose subprocess has not yet completed — the set shutdown
    /// must cancel and wait for.
    var allLive: [ScanInterruptQualProbe] { Array(live.values) }

    var liveCount: Int { live.count }
}
