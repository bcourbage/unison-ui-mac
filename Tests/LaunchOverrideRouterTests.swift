import XCTest
@testable import unison_ui_mac

/// The launch → picker routing sequence (the exact logic AppDelegate uses at the
/// named-launch site and the picker callback). Inheritance is CHOSEN separately
/// from being CONSUMED, so a selection refused before it opens leaves inheritance
/// pending for the retry.
final class LaunchOverrideRouterTests: XCTestCase {

    /// `unison -ui graphic -path Documents` (no profile) → picker: the first
    /// ACCEPTED open inherits, later ones are explicit.
    func test_firstAcceptedOpen_inherits_restExplicit() {
        var r = LaunchOverrideRouter()
        let a = r.overrideForNextOpen()
        XCTAssertEqual(a, .inheritLaunch, "first launch-origin open inherits the launch argv")
        r.didOpen(a, accepted: true)
        let b = r.overrideForNextOpen()
        XCTAssertEqual(b, .explicit([]), "second selection is explicitly unscoped")
        r.didOpen(b, accepted: true)
        XCTAssertEqual(r.overrideForNextOpen(), .explicit([]))
    }

    /// The reported regression: a first selection refused by an archive-recovery
    /// block must NOT consume inheritance, so the retry after recovery still
    /// inherits; only then does a subsequent selection become unscoped.
    func test_refusedFirstSelection_keepsPending_retryInherits_thenExplicit() {
        var r = LaunchOverrideRouter()
        let refused = r.overrideForNextOpen()
        XCTAssertEqual(refused, .inheritLaunch)
        r.didOpen(refused, accepted: false)          // refused before opening

        let retry = r.overrideForNextOpen()
        XCTAssertEqual(retry, .inheritLaunch,
                       "a refused first selection must leave inheritance pending for the retry")
        r.didOpen(retry, accepted: true)             // recovery cleared → accepted

        let next = r.overrideForNextOpen()
        XCTAssertEqual(next, .explicit([]),
                       "after the retry claims inheritance, later selections are unscoped")
        r.didOpen(next, accepted: true)
    }

    /// A refusal of a later (already-explicit) selection changes nothing.
    func test_refusedLaterSelection_staysExplicit() {
        var r = LaunchOverrideRouter()
        let first = r.overrideForNextOpen(); r.didOpen(first, accepted: true)   // inherit consumed
        let refused = r.overrideForNextOpen()
        XCTAssertEqual(refused, .explicit([]))
        r.didOpen(refused, accepted: false)
        XCTAssertEqual(r.overrideForNextOpen(), .explicit([]))
    }

    /// Nothing to inherit (no graphical launch session): every selection is
    /// explicitly unscoped from the start.
    func test_noInheritableLaunch_everyOpenExplicit() {
        var r = LaunchOverrideRouter(launchCanInherit: false)
        let a = r.overrideForNextOpen()
        XCTAssertEqual(a, .explicit([]))
        r.didOpen(a, accepted: true)
        XCTAssertEqual(r.overrideForNextOpen(), .explicit([]))
    }
}
