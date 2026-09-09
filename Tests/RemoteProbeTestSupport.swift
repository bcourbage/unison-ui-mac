import Foundation

/// Shared bounds for the tests that drive the REAL subprocess executor
/// (RemoteCheckSessionTests, RemoteDiscoveryTests) with /bin/sh standing in for
/// ssh.
enum RemoteProbeTestSupport {

    /// Wall-clock deadline for a functional probe whose child does trivial work
    /// and is EXPECTED to exit on its own. The child normally exits in
    /// milliseconds; this bound is only a safety net so a genuinely hung test
    /// fails the suite instead of blocking it forever.
    ///
    /// It is set generously to tolerate slow child teardown on a loaded CI
    /// runner, which has produced intermittent false timeouts: the probe's
    /// output was captured in full, yet the executor reported deadlineExpired.
    /// This is a mitigation for that flake, not a fix for its cause. Whether the
    /// lag is delayed Foundation reaping of the exited child or fd churn during
    /// collection is not yet established, and a larger bound settles neither;
    /// nor does it establish that a production remote check (which carries its
    /// own deadline as a real liveness bound) is unaffected. Tests that
    /// deliberately exercise the deadline keep their own short values.
    static let functionalDeadline: TimeInterval = 120
}
