import XCTest
@testable import unison_ui_mac

/// Turns on the subprocess executor's opt-in lifecycle timing for the whole
/// test bundle and points it at a deterministic file the CI job reads.
///
/// The executor is env-gated (`UUM_PROBE_TIMING`) and off in production, which
/// never loads this bundle. Setting the variable from the launching shell does
/// not reach a hosted unit-test host, so the test target opts itself in here
/// instead, with `setenv` (the executor reads it live via `getenv`). This is the
/// investigation into why an already-complete probe can still reach its
/// deadline; it records timing only and changes no production behavior.
///
/// `activate()` is idempotent and called from the probe test classes' class
/// setUp, so it runs before any probe. Honors a pre-set `UUM_PROBE_TIMING_FILE`;
/// otherwise defaults to a fixed path the CI step knows.
enum ProbeTimingBootstrap {
    static let defaultFile = "/tmp/uum-probe-timing.log"

    static func activate() { _ = once }

    private static let once: Void = {
        if getenv("UUM_PROBE_TIMING") == nil { setenv("UUM_PROBE_TIMING", "1", 1) }
        if getenv("UUM_PROBE_TIMING_FILE") == nil { setenv("UUM_PROBE_TIMING_FILE", defaultFile, 1) }
        if let c = getenv("UUM_PROBE_TIMING_FILE") { unlink(c) }   // fresh file per bundle run
    }()
}
