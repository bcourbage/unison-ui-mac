import XCTest
import AppKit
@testable import unison_ui_mac

/// Pins the (direction, override) → (glyph, tint) and the FolderAggregate
/// → (glyph, tint) mappings. The override distinction is the subtle bit:
/// for `.skip` the underlying OCaml direction is always `"<-?->"`, but
/// for `.forceOlder`/`.forceNewer` the resulting direction is `"---->"`
/// or `"<----"` (mtime-resolved) — the override MUST hide that arrow so
/// the user sees the *decision* (forced) rather than the *result*
/// (an arbitrary-looking left/right pick). Easy to break, hard to notice
/// on a visual smoke test.
final class DirectionVisualTests: XCTestCase {

    // Reference hex colors. Kept here too so a change to the palette
    // shows up in a code-review diff as a test edit.
    private let greenHex = NSColor(red: 0x97/255.0, green: 0xBB/255.0, blue: 0x68/255.0, alpha: 1.0)
    private let blueHex  = NSColor(red: 0x5A/255.0, green: 0x96/255.0, blue: 0xDE/255.0, alpha: 1.0)

    private func assertColor(_ actual: NSColor,
                             matchesRGB expected: NSColor,
                             alpha: CGFloat? = nil,
                             tolerance: CGFloat = 0.01,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        // Normalize both into deviceRGB before comparing components — NSColor
        // comparisons across color spaces (e.g., sRGB vs deviceRGB) trip up.
        guard let a = actual.usingColorSpace(.deviceRGB),
              let e = expected.usingColorSpace(.deviceRGB) else {
            XCTFail("could not convert colors to deviceRGB", file: file, line: line)
            return
        }
        XCTAssertEqual(a.redComponent,   e.redComponent,   accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(a.greenComponent, e.greenComponent, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(a.blueComponent,  e.blueComponent,  accuracy: tolerance, file: file, line: line)
        if let expectedAlpha = alpha {
            XCTAssertEqual(a.alphaComponent, expectedAlpha, accuracy: tolerance, file: file, line: line)
        }
    }

    // MARK: - Leaf glyph (no override)

    func test_leaf_glyph_toSecond() {
        // `---->` = propagate first → second replica → right arrow.
        XCTAssertEqual(DirectionVisual.glyph(for: "---->", override: nil), "→")
    }

    func test_leaf_glyph_toFirst() {
        // `<----` = propagate second → first replica → left arrow.
        XCTAssertEqual(DirectionVisual.glyph(for: "<----", override: nil), "←")
    }

    func test_leaf_glyph_autoConflict() {
        XCTAssertEqual(DirectionVisual.glyph(for: "<-?->", override: nil), "⚠︎",
                       "auto-detected conflict shows warning triangle")
    }

    func test_leaf_glyph_merge() {
        XCTAssertEqual(DirectionVisual.glyph(for: "<-M->", override: nil), "M")
    }

    func test_leaf_glyph_unknownDirectionPassesThrough() {
        // Defensive default — surfaces unrecognized OCaml output as-is
        // so it can be debugged from the UI without crashing.
        XCTAssertEqual(DirectionVisual.glyph(for: "??", override: nil), "??")
    }

    // MARK: - Override-driven glyphs (the key correctness story)

    func test_leaf_glyph_skipOverride_isCircledMinus_regardlessOfDirection() {
        // User chose Skip — visual must be ⊖ regardless of what OCaml
        // says about direction. The whole point of the override is to
        // surface user intent over auto-resolution.
        XCTAssertEqual(DirectionVisual.glyph(for: "<-?->", override: .skip), "⊖")
        XCTAssertEqual(DirectionVisual.glyph(for: "---->", override: .skip), "⊖")
        XCTAssertEqual(DirectionVisual.glyph(for: "<----", override: .skip), "⊖")
    }

    func test_leaf_glyph_forceOlderOverride_isCounterclockwiseArrow_hidingDirection() {
        // The result direction is "---->" or "<----" depending on mtime —
        // both must render the same forced-older glyph. Otherwise the
        // user couldn't tell whether they clicked → Second or Force
        // Older (with mtime happening to land on First's side).
        XCTAssertEqual(DirectionVisual.glyph(for: "---->", override: .forceOlder), "↺")
        XCTAssertEqual(DirectionVisual.glyph(for: "<----", override: .forceOlder), "↺")
    }

    func test_leaf_glyph_forceNewerOverride_isClockwiseArrow_hidingDirection() {
        XCTAssertEqual(DirectionVisual.glyph(for: "---->", override: .forceNewer), "↻")
        XCTAssertEqual(DirectionVisual.glyph(for: "<----", override: .forceNewer), "↻")
    }

    func test_leaf_glyph_forceOlderAndNewer_areVisuallyDistinct() {
        // Same row direction, different overrides → different glyphs.
        // The whole feature relies on this being true.
        let older = DirectionVisual.glyph(for: "---->", override: .forceOlder)
        let newer = DirectionVisual.glyph(for: "---->", override: .forceNewer)
        XCTAssertNotEqual(older, newer)
    }

    // MARK: - Leaf tint (no override)

    func test_leaf_tint_toSecond_isExactGreenHex() {
        assertColor(DirectionVisual.tint(for: "---->", override: nil), matchesRGB: greenHex)
    }

    func test_leaf_tint_toFirst_isExactBlueHex() {
        assertColor(DirectionVisual.tint(for: "<----", override: nil), matchesRGB: blueHex)
    }

    func test_leaf_tint_autoConflict_isOrange() {
        let tint = DirectionVisual.tint(for: "<-?->", override: nil)
        let oranged = tint.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(oranged.redComponent, oranged.blueComponent,
                             "orange should have more red than blue")
    }

    func test_leaf_tint_unknownDirection_isClear() {
        let tint = DirectionVisual.tint(for: "??", override: nil)
        XCTAssertEqual(tint, .clear)
    }

    // MARK: - Override-driven tints

    func test_leaf_tint_skipOverride_isNeutralGray() {
        let tint = DirectionVisual.tint(for: "<-?->", override: .skip)
            .usingColorSpace(.deviceRGB)!
        // Gray = all RGB components approximately equal.
        XCTAssertEqual(tint.redComponent, tint.greenComponent, accuracy: 0.1,
                       "gray should have equal RGB components")
        XCTAssertEqual(tint.greenComponent, tint.blueComponent, accuracy: 0.1)
        XCTAssertLessThan(tint.alphaComponent, 1.0,
                          "settled state is rendered with reduced alpha")
    }

    func test_leaf_tint_forceOlder_isBrownish() {
        // Brown = red + green > blue. Matches DirectionAction.forceOlder's
        // toolbar accent so the cell and the menu that produced it agree.
        let tint = DirectionVisual.tint(for: "---->", override: .forceOlder)
            .usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(tint.redComponent, tint.blueComponent)
        XCTAssertGreaterThan(tint.greenComponent, tint.blueComponent)
        XCTAssertLessThan(tint.alphaComponent, 1.0)
    }

    func test_leaf_tint_forceNewer_isTealish() {
        // Teal = green + blue > red.
        let tint = DirectionVisual.tint(for: "---->", override: .forceNewer)
            .usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(tint.greenComponent, tint.redComponent)
        XCTAssertGreaterThan(tint.blueComponent, tint.redComponent)
        XCTAssertLessThan(tint.alphaComponent, 1.0)
    }

    func test_leaf_tint_forceOlderAndNewer_areVisuallyDistinct() {
        let older = DirectionVisual.tint(for: "---->", override: .forceOlder)
            .usingColorSpace(.deviceRGB)!
        let newer = DirectionVisual.tint(for: "---->", override: .forceNewer)
            .usingColorSpace(.deviceRGB)!
        // Different hues — at least one channel differs by a clear margin.
        let redDelta = abs(older.redComponent - newer.redComponent)
        let blueDelta = abs(older.blueComponent - newer.blueComponent)
        XCTAssertGreaterThan(max(redDelta, blueDelta), 0.1,
                             "force-older and force-newer must use distinguishable tints")
    }

    // MARK: - Folder aggregate glyph/tint

    func test_aggregate_glyph_uniformDelegatesToLeafGlyph() {
        XCTAssertEqual(DirectionVisual.glyph(for: .uniform("---->")), "→")
        XCTAssertEqual(DirectionVisual.glyph(for: .uniform("<----")), "←")
        XCTAssertEqual(DirectionVisual.glyph(for: .uniform("<-?->")), "⚠︎",
                       "uniform conflict — the folder is itself a conflict; overrides are per-leaf, not aggregate")
        XCTAssertEqual(DirectionVisual.glyph(for: .uniform("<-M->")), "M")
    }

    func test_aggregate_glyph_allUserSkipped() {
        XCTAssertEqual(DirectionVisual.glyph(for: .allUserSkipped), "⊖")
    }

    func test_aggregate_glyph_allForcedOlder() {
        XCTAssertEqual(DirectionVisual.glyph(for: .allForcedOlder), "↺",
                       "folder with every leaf set to Force Older shows the older-decision glyph")
    }

    func test_aggregate_glyph_allForcedNewer() {
        XCTAssertEqual(DirectionVisual.glyph(for: .allForcedNewer), "↻")
    }

    func test_aggregate_glyph_mixed_isEmptyString() {
        XCTAssertEqual(DirectionVisual.glyph(for: .mixed), "",
                       "mixed folders show no badge — user must drill in")
    }

    func test_aggregate_tint_uniformReusesLeafColors() {
        assertColor(DirectionVisual.tint(for: .uniform("---->")), matchesRGB: greenHex)
        assertColor(DirectionVisual.tint(for: .uniform("<----")), matchesRGB: blueHex)
    }

    func test_aggregate_tint_mixed_isClear() {
        XCTAssertEqual(DirectionVisual.tint(for: .mixed), .clear)
    }

    func test_aggregate_tint_allUserSkipped_isGrayWithReducedAlpha() {
        let tint = DirectionVisual.tint(for: .allUserSkipped).usingColorSpace(.deviceRGB)!
        XCTAssertEqual(tint.redComponent, tint.greenComponent, accuracy: 0.1)
        XCTAssertEqual(tint.greenComponent, tint.blueComponent, accuracy: 0.1)
        XCTAssertLessThan(tint.alphaComponent, 1.0)
    }

    func test_aggregate_tint_allForcedOlder_matchesLeafForcedOlder() {
        // The aggregate tint MUST equal the per-leaf forced-older tint
        // so a fully-forced folder visually agrees with its descendants.
        let aggregate = DirectionVisual.tint(for: .allForcedOlder)
        let leaf = DirectionVisual.tint(for: "---->", override: .forceOlder)
        assertColor(aggregate, matchesRGB: leaf)
    }

    func test_aggregate_tint_allForcedNewer_matchesLeafForcedNewer() {
        let aggregate = DirectionVisual.tint(for: .allForcedNewer)
        let leaf = DirectionVisual.tint(for: "<----", override: .forceNewer)
        assertColor(aggregate, matchesRGB: leaf)
    }
}
