import XCTest
@testable import unison_ui_mac

/// The launch → picker routing sequence (the exact logic AppDelegate uses at the
/// named-launch site and the picker callback). The launch's own options are
/// delivered to the first ACCEPTED launch-origin open; a selection refused before
/// it opens leaves them pending for the retry; later selections are unscoped.
final class LaunchOverrideRouterTests: XCTestCase {

    /// `unison -ui graphic -path Documents` (no profile) → picker: the first
    /// accepted open receives the launch args, later ones are unscoped.
    func test_firstAcceptedOpen_getsLaunchArgs_restEmpty() {
        var r = LaunchOverrideRouter(launchArgs: ["-path", "Documents"])
        let a = r.argsForNextOpen()
        XCTAssertEqual(a, ["-path", "Documents"], "first launch-origin open gets the launch args")
        r.didOpen(accepted: true)
        XCTAssertEqual(r.argsForNextOpen(), [], "later selection is unscoped")
        r.didOpen(accepted: true)
        XCTAssertEqual(r.argsForNextOpen(), [])
    }

    /// A first selection refused (e.g. an archive-recovery block) must NOT consume
    /// the launch args, so the retry after recovery still receives them; only then
    /// does a subsequent selection become unscoped.
    func test_refusedFirstSelection_keepsPending_retryGetsArgs_thenEmpty() {
        var r = LaunchOverrideRouter(launchArgs: ["-path", "Documents"])
        let refused = r.argsForNextOpen()
        XCTAssertEqual(refused, ["-path", "Documents"])
        r.didOpen(accepted: false)                       // refused before opening

        let retry = r.argsForNextOpen()
        XCTAssertEqual(retry, ["-path", "Documents"],
                       "a refused first selection must leave the launch args pending for the retry")
        r.didOpen(accepted: true)                        // recovery cleared → accepted

        XCTAssertEqual(r.argsForNextOpen(), [], "after the retry claims them, later selections are unscoped")
    }

    /// Nothing to deliver (Finder launch, or a launch with no session options):
    /// every selection is unscoped.
    func test_noLaunchArgs_everyOpenEmpty() {
        var r = LaunchOverrideRouter(launchArgs: nil)
        XCTAssertEqual(r.argsForNextOpen(), [])
        r.didOpen(accepted: true)
        XCTAssertEqual(r.argsForNextOpen(), [])

        var r2 = LaunchOverrideRouter()   // default init
        XCTAssertEqual(r2.argsForNextOpen(), [])
    }
}
