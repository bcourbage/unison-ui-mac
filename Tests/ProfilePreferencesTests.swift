import XCTest
@testable import unison_ui_mac

/// Tests for the apply(filter+sort) logic and the toggleHidden/forget
/// helpers. Persistence uses an isolated UserDefaults suite so the tests
/// don't leak state into the real domain.
final class ProfilePreferencesTests: XCTestCase {

    // MARK: - apply()

    func test_apply_defaultPrefs_returnsAlphabetical() {
        let prefs = ProfilePreferences()
        let result = prefs.apply(to: ["banana", "apple", "cherry"], includeHidden: false)
        XCTAssertEqual(result, ["apple", "banana", "cherry"])
    }

    func test_apply_withCustomOrder_putsListedProfilesFirstInOrder() {
        let prefs = ProfilePreferences(order: ["cherry", "apple"])
        // banana isn't in the order list — falls to alphabetical at the end.
        let result = prefs.apply(to: ["banana", "apple", "cherry"], includeHidden: false)
        XCTAssertEqual(result, ["cherry", "apple", "banana"])
    }

    func test_apply_orderEntriesForMissingProfiles_areSilentlyDropped() {
        // User reordered with profile "ghost" in the list, then deleted
        // the .prf externally. The stale entry shouldn't break anything
        // or appear in the result.
        let prefs = ProfilePreferences(order: ["ghost", "apple"])
        let result = prefs.apply(to: ["apple", "banana"], includeHidden: false)
        XCTAssertEqual(result, ["apple", "banana"])
    }

    func test_apply_remainingProfiles_areSortedLocaleAware() {
        // The fallback alphabetical sort uses Swift's String < operator,
        // which is locale-aware via NSString comparison rules. We don't
        // care about exact collation, just that ordering is deterministic.
        let prefs = ProfilePreferences()
        let result = prefs.apply(to: ["zeta", "alpha", "Gamma", "beta"],
                                 includeHidden: false)
        XCTAssertEqual(result.first, "Gamma")  // Uppercase sorts before lowercase
        XCTAssertEqual(result.last, "zeta")
    }

    func test_apply_hidesEntriesInTheHiddenSet_unlessIncludeHiddenIsTrue() {
        let prefs = ProfilePreferences(hidden: ["banana"], order: [])
        XCTAssertEqual(
            prefs.apply(to: ["apple", "banana", "cherry"], includeHidden: false),
            ["apple", "cherry"]
        )
        // Editor view: hidden profiles still visible so they can be unhidden.
        XCTAssertEqual(
            prefs.apply(to: ["apple", "banana", "cherry"], includeHidden: true),
            ["apple", "banana", "cherry"]
        )
    }

    func test_apply_hiddenEntriesStillRespectCustomOrderInEditorView() {
        // In the editor, the user sees everything — and the order they
        // dragged earlier should still apply, even to currently-hidden
        // rows, so the editor list doesn't reshuffle when you toggle hide.
        let prefs = ProfilePreferences(hidden: ["banana"],
                                       order: ["cherry", "banana", "apple"])
        XCTAssertEqual(
            prefs.apply(to: ["banana", "apple", "cherry"], includeHidden: true),
            ["cherry", "banana", "apple"]
        )
    }

    // MARK: - Mutations

    func test_toggleHidden_isIdempotentInTwoSteps() {
        var prefs = ProfilePreferences()
        prefs.toggleHidden("foo")
        XCTAssertTrue(prefs.hidden.contains("foo"))
        prefs.toggleHidden("foo")
        XCTAssertFalse(prefs.hidden.contains("foo"))
    }

    func test_forget_removesProfileFromBothHiddenAndOrder() {
        var prefs = ProfilePreferences(hidden: ["foo", "bar"],
                                       order: ["foo", "baz", "bar"])
        prefs.forget("foo")
        XCTAssertEqual(prefs.hidden, ["bar"])
        XCTAssertEqual(prefs.order, ["baz", "bar"])
    }

    // MARK: - Persistence round-trip

    func test_persistence_roundTripsHiddenAndOrder() {
        // Use an isolated suite so the test doesn't pollute the real
        // user-default domain. The suite name is throwaway.
        let suiteName = "ProfilePreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = ProfilePreferences(hidden: ["x", "y"],
                                       order: ["b", "a", "c"])
        prefs.save(to: defaults)

        let reloaded = ProfilePreferences.load(from: defaults)
        XCTAssertEqual(reloaded.hidden, ["x", "y"])
        XCTAssertEqual(reloaded.order, ["b", "a", "c"])
    }

    func test_persistence_missingKeys_yieldEmptyPrefs() {
        let suiteName = "ProfilePreferencesTests-empty-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = ProfilePreferences.load(from: defaults)
        XCTAssertTrue(prefs.hidden.isEmpty)
        XCTAssertTrue(prefs.order.isEmpty)
    }

    // MARK: - rename()

    func test_rename_movesProfileInOrderList() {
        var prefs = ProfilePreferences(hidden: [],
                                       order: ["foo", "bar", "baz"])
        prefs.rename("bar", to: "barrr")
        XCTAssertEqual(prefs.order, ["foo", "barrr", "baz"])
        XCTAssertTrue(prefs.hidden.isEmpty)
    }

    func test_rename_movesProfileInHiddenSet() {
        var prefs = ProfilePreferences(hidden: ["bar"], order: [])
        prefs.rename("bar", to: "barrr")
        XCTAssertEqual(prefs.hidden, ["barrr"])
    }

    func test_rename_updatesBothOrderAndHiddenForSameProfile() {
        var prefs = ProfilePreferences(hidden: ["bar"],
                                       order: ["foo", "bar", "baz"])
        prefs.rename("bar", to: "barrr")
        XCTAssertEqual(prefs.order, ["foo", "barrr", "baz"])
        XCTAssertEqual(prefs.hidden, ["barrr"])
    }

    func test_rename_isNoOpWhenOldNameNotTracked() {
        var prefs = ProfilePreferences(hidden: ["x"], order: ["a", "b"])
        prefs.rename("ghost", to: "still-ghost")
        XCTAssertEqual(prefs.order, ["a", "b"])
        XCTAssertEqual(prefs.hidden, ["x"])
    }

    func test_rename_sameName_isNoOp() {
        // Defensive — caller shouldn't do this but harmless.
        var prefs = ProfilePreferences(hidden: ["x"], order: ["a", "x", "b"])
        prefs.rename("x", to: "x")
        XCTAssertEqual(prefs.order, ["a", "x", "b"])
        XCTAssertEqual(prefs.hidden, ["x"])
    }

    // MARK: - reorder()
    //
    // The drop-row math is the kind of code that's easy to get subtly
    // wrong (off-by-one when the moved row is before the drop target).
    // Each test pins one scenario; together they cover the corner cases
    // the AppKit drag-drop API throws at us.

    func test_reorder_moveDownByOne() {
        // Drag "a" (at index 0) to drop row 2 (between "b" and "c").
        // Without compensation, naive remove-then-insert would yield
        // [b, a, c] (insertion at adjusted index 1). With compensation,
        // we want "a" between "b" and "c": [b, a, c]. Both happen to
        // agree here — but the test confirms the small-move case works.
        let result = ProfilePreferences.reorder(["a", "b", "c"],
                                                moving: ["a"],
                                                toDropRow: 2)
        XCTAssertEqual(result, ["b", "a", "c"])
    }

    func test_reorder_moveToBottom() {
        // Drag "a" to drop row 3 (end). Result: a at the end.
        let result = ProfilePreferences.reorder(["a", "b", "c"],
                                                moving: ["a"],
                                                toDropRow: 3)
        XCTAssertEqual(result, ["b", "c", "a"])
    }

    func test_reorder_moveToTop() {
        // Drag "c" to drop row 0 (before the first row).
        let result = ProfilePreferences.reorder(["a", "b", "c"],
                                                moving: ["c"],
                                                toDropRow: 0)
        XCTAssertEqual(result, ["c", "a", "b"])
    }

    func test_reorder_moveUpFromMiddle() {
        // Drag "c" (index 2) to drop row 1 (between "a" and "b").
        // No removals before the drop row, so insertion sits at 1.
        let result = ProfilePreferences.reorder(["a", "b", "c", "d"],
                                                moving: ["c"],
                                                toDropRow: 1)
        XCTAssertEqual(result, ["a", "c", "b", "d"])
    }

    func test_reorder_dropAtOwnIndex_isNoOp() {
        // Drag "b" to drop row 1 (its own position). Move ends up as
        // a no-op since removing then re-inserting at the compensated
        // index lands it back where it was.
        let result = ProfilePreferences.reorder(["a", "b", "c"],
                                                moving: ["b"],
                                                toDropRow: 1)
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func test_reorder_dropAtOwnIndexPlusOne_isAlsoNoOp() {
        // Drag "b" to drop row 2. The user is asking to put "b" right
        // after its current position — also a no-op after removal
        // compensation (drop adjusted to 1 = its original spot).
        let result = ProfilePreferences.reorder(["a", "b", "c"],
                                                moving: ["b"],
                                                toDropRow: 2)
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func test_reorder_unknownNames_areIgnored() {
        // A name that isn't in `current` (e.g. stale pasteboard payload
        // after the manager was reloaded) must not corrupt the array.
        let result = ProfilePreferences.reorder(["a", "b", "c"],
                                                moving: ["ghost"],
                                                toDropRow: 1)
        XCTAssertEqual(result, ["a", "b", "c"])
    }

    func test_reorder_emptyMoving_returnsCurrentUnchanged() {
        let result = ProfilePreferences.reorder(["a", "b"], moving: [],
                                                toDropRow: 1)
        XCTAssertEqual(result, ["a", "b"])
    }

    func test_reorder_duplicatesInMoving_areDeduplicated() {
        // Defensive — shouldn't happen via NSTableView drag but be safe.
        let result = ProfilePreferences.reorder(["a", "b", "c"],
                                                moving: ["a", "a"],
                                                toDropRow: 3)
        XCTAssertEqual(result, ["b", "c", "a"])
    }

    func test_reorder_multipleMoved_preservesMovingOrderAtDestination() {
        // If we ever enable multi-row drag (allowsMultipleSelection),
        // the moved set should land in the destination in the order
        // it appears in `moving`, not in their original positions.
        // Drop row 1 = "between current[0] and current[1]" — so the
        // moved set lands right after "a".
        //
        // Trace:
        //   movedIndices = [3, 1]; only index 1 is < dropRow 1? No,
        //   neither is < 1. removalsBeforeDrop = 0, insertionRow = 1.
        //   After removal: ["a", "c", "e"]; insert ["d", "b"] at 1 →
        //   ["a", "d", "b", "c", "e"].
        let result = ProfilePreferences.reorder(["a", "b", "c", "d", "e"],
                                                moving: ["d", "b"],
                                                toDropRow: 1)
        XCTAssertEqual(result, ["a", "d", "b", "c", "e"])
    }

    func test_reorder_multipleMoved_dropAfterBoth_compensatesForRemovals() {
        // Both moved items sit BEFORE the drop row, so the insertion
        // index needs to be adjusted by 2.
        //   movedIndices = [0, 1]; both < dropRow 4 → removalsBeforeDrop = 2.
        //   insertionRow = 4 - 2 = 2. After removal: ["c", "d", "e"];
        //   insert ["a", "b"] at 2 → ["c", "d", "a", "b", "e"].
        let result = ProfilePreferences.reorder(["a", "b", "c", "d", "e"],
                                                moving: ["a", "b"],
                                                toDropRow: 4)
        XCTAssertEqual(result, ["c", "d", "a", "b", "e"])
    }

    func test_reorder_dropRowOutOfRange_isClamped() {
        // NSTableView shouldn't hand us out-of-range indexes, but clamp
        // defensively rather than crash.
        let high = ProfilePreferences.reorder(["a", "b"], moving: ["a"],
                                              toDropRow: 99)
        XCTAssertEqual(high, ["b", "a"])
        let low = ProfilePreferences.reorder(["a", "b"], moving: ["b"],
                                             toDropRow: -5)
        XCTAssertEqual(low, ["b", "a"])
    }
}
