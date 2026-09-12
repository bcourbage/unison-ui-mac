import XCTest
@testable import unison_ui_mac

/// The launch → picker routing sequence (the exact logic AppDelegate uses at the
/// named-launch site and the picker callback). Covers the regression: an option
/// launch that names NO profile must let the FIRST picker selection inherit the
/// launch command line, while later selections stay explicitly unscoped.
final class LaunchOverrideRouterTests: XCTestCase {

    /// `unison -ui graphic -path Documents` (no profile) → picker → the first
    /// pick inherits, the rest are explicit.
    func test_optionLaunchNoProfile_firstPickInherits_restExplicit() {
        var r = LaunchOverrideRouter()
        XCTAssertEqual(r.forPickerSelection(), .inheritLaunch,
                       "first picker selection after an option launch inherits the launch argv")
        XCTAssertEqual(r.forPickerSelection(), .explicit([]),
                       "second selection is explicitly unscoped")
        XCTAssertEqual(r.forPickerSelection(), .explicit([]))
    }

    /// A launch that names a profile claims inheritance for that session; later
    /// picker selections are explicit.
    func test_namedLaunchProfile_claimsInheritance_thenPicksExplicit() {
        var r = LaunchOverrideRouter()
        XCTAssertEqual(r.forLaunchProfile(), .inheritLaunch)
        XCTAssertEqual(r.forPickerSelection(), .explicit([]),
                       "the named launch profile already claimed inheritance")
        XCTAssertEqual(r.forPickerSelection(), .explicit([]))
    }

    /// Nothing to inherit (no graphical launch session): every picker selection
    /// is explicitly unscoped from the start.
    func test_noInheritableLaunch_everyPickExplicit() {
        var r = LaunchOverrideRouter(launchCanInherit: false)
        XCTAssertEqual(r.forPickerSelection(), .explicit([]))
        XCTAssertEqual(r.forPickerSelection(), .explicit([]))
    }
}
