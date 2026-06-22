import XCTest
@testable import unison_ui_mac

/// Pins the tri-state boolean-pref mapping in the Profile Editor's
/// Default/On/Off popups (fastcheck, auto, confirmbigdel, rsrc, owner,
/// group, dontchmod, times).
///
/// Regression context: the mapping originally recognized only
/// `true`/`false`. A `.prf` written with Unison's equally-valid `yes`/`no`
/// spelling (e.g. `fastcheck = no`) fell through to "Default" — the
/// setting looked absent in the editor AND, because Default persists as
/// "omit the key", it was silently DELETED on the next save. These tests
/// lock in the full Unison boolean vocabulary and the round-trip.
final class TriStatePrefTests: XCTestCase {

    typealias TS = ProfileFormWindowController

    // MARK: - On

    func test_true_isOn() {
        XCTAssertEqual(TS.triState(forPrefValue: "true"), .on)
    }

    func test_yes_isOn() {
        XCTAssertEqual(TS.triState(forPrefValue: "yes"), .on)
    }

    func test_bareKey_emptyString_isOn() {
        // A bare `fastcheck` line (no `= value`) means true in Unison.
        XCTAssertEqual(TS.triState(forPrefValue: ""), .on)
    }

    func test_caseInsensitive_On() {
        XCTAssertEqual(TS.triState(forPrefValue: "YES"), .on)
        XCTAssertEqual(TS.triState(forPrefValue: "True"), .on)
    }

    // MARK: - Off

    func test_false_isOff() {
        XCTAssertEqual(TS.triState(forPrefValue: "false"), .off)
    }

    func test_no_isOff() {
        // The exact reported bug: `fastcheck = no` must be Off, not Default.
        XCTAssertEqual(TS.triState(forPrefValue: "no"), .off)
    }

    func test_caseInsensitive_Off() {
        XCTAssertEqual(TS.triState(forPrefValue: "NO"), .off)
        XCTAssertEqual(TS.triState(forPrefValue: "False"), .off)
    }

    // MARK: - Default

    func test_absent_isDefault() {
        XCTAssertEqual(TS.triState(forPrefValue: nil), .default)
    }

    func test_literalDefault_isDefault() {
        XCTAssertEqual(TS.triState(forPrefValue: "default"), .default)
    }

    func test_unrecognized_isDefault() {
        XCTAssertEqual(TS.triState(forPrefValue: "maybe"), .default)
    }

    // MARK: - Save mapping + round-trip

    func test_prefValue_onOffDefault() {
        XCTAssertEqual(TS.prefValue(forTriState: .on), "true")
        XCTAssertEqual(TS.prefValue(forTriState: .off), "false")
        XCTAssertNil(TS.prefValue(forTriState: .default))
    }

    func test_no_roundTrips_toOff_notDropped() {
        // The data-loss guard: `no` loads as Off and saves back as a real
        // value (normalized to "false"), never nil/dropped.
        let loaded = TS.triState(forPrefValue: "no")
        XCTAssertEqual(loaded, .off)
        XCTAssertEqual(TS.prefValue(forTriState: loaded), "false")
    }

    func test_rawValues_matchPopupOrder() {
        // rawValue doubles as the selectItem(at:) index; order must match
        // addItems(withTitles: ["Default","On","Off"]).
        XCTAssertEqual(TS.TriState.default.rawValue, 0)
        XCTAssertEqual(TS.TriState.on.rawValue, 1)
        XCTAssertEqual(TS.TriState.off.rawValue, 2)
    }
}
