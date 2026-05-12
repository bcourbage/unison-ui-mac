import XCTest
import AppKit
@testable import unison_ui_mac

/// Pins the (direction, isUserSkipped) → (glyph, tint) and the
/// FolderAggregate → (glyph, tint) mappings. The user-skip distinction
/// is the subtle bit: "<-?->" with `isUserSkipped == true` MUST render
/// differently from the same string with `isUserSkipped == false` —
/// the former is settled (gray ⊖), the latter needs attention (orange ⚠︎).
/// Easy to break, hard to notice on a visual smoke test.
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

    // MARK: - Leaf glyph (direction + isUserSkipped)

    func test_leaf_glyph_toRemote() {
        XCTAssertEqual(DirectionVisual.glyph(for: "---->", isUserSkipped: false), "→")
    }

    func test_leaf_glyph_toLocal() {
        XCTAssertEqual(DirectionVisual.glyph(for: "<----", isUserSkipped: false), "←")
    }

    func test_leaf_glyph_autoConflict() {
        XCTAssertEqual(DirectionVisual.glyph(for: "<-?->", isUserSkipped: false), "⚠︎",
                       "auto-detected conflict shows warning triangle")
    }

    func test_leaf_glyph_userSkippedConflict_isCircledMinus() {
        XCTAssertEqual(DirectionVisual.glyph(for: "<-?->", isUserSkipped: true), "⊖",
                       "user-skipped row must visually differ from auto-conflict — this is the whole point")
    }

    func test_leaf_glyph_merge() {
        XCTAssertEqual(DirectionVisual.glyph(for: "<-M->", isUserSkipped: false), "M")
    }

    func test_leaf_glyph_isUserSkippedIgnoredForNonConflictDirections() {
        // The userSkipped flag only flips behavior for "<-?->".
        // Spurious "userSkipped: true" on a directional row must not
        // accidentally show ⊖.
        XCTAssertEqual(DirectionVisual.glyph(for: "---->", isUserSkipped: true), "→")
        XCTAssertEqual(DirectionVisual.glyph(for: "<----", isUserSkipped: true), "←")
        XCTAssertEqual(DirectionVisual.glyph(for: "<-M->", isUserSkipped: true), "M")
    }

    func test_leaf_glyph_unknownDirectionPassesThrough() {
        // Defensive default — surfaces unrecognized OCaml output as-is
        // so it can be debugged from the UI without crashing.
        XCTAssertEqual(DirectionVisual.glyph(for: "??", isUserSkipped: false), "??")
    }

    // MARK: - Leaf tint

    func test_leaf_tint_toRemote_isExactGreenHex() {
        assertColor(DirectionVisual.tint(for: "---->", isUserSkipped: false), matchesRGB: greenHex)
    }

    func test_leaf_tint_toLocal_isExactBlueHex() {
        assertColor(DirectionVisual.tint(for: "<----", isUserSkipped: false), matchesRGB: blueHex)
    }

    func test_leaf_tint_autoConflict_isOrange() {
        let tint = DirectionVisual.tint(for: "<-?->", isUserSkipped: false)
        let oranged = tint.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(oranged.redComponent, oranged.blueComponent,
                             "orange should have more red than blue")
    }

    func test_leaf_tint_userSkippedConflict_isNeutralGray() {
        let tint = DirectionVisual.tint(for: "<-?->", isUserSkipped: true)
        let gray = tint.usingColorSpace(.deviceRGB)!
        // Gray = all RGB components approximately equal.
        XCTAssertEqual(gray.redComponent, gray.greenComponent, accuracy: 0.1,
                       "gray should have equal RGB components")
        XCTAssertEqual(gray.greenComponent, gray.blueComponent, accuracy: 0.1)
        XCTAssertLessThan(gray.alphaComponent, 1.0,
                          "settled state is rendered with reduced alpha")
    }

    func test_leaf_tint_unknownDirection_isClear() {
        let tint = DirectionVisual.tint(for: "??", isUserSkipped: false)
        XCTAssertEqual(tint, .clear)
    }

    // MARK: - Folder aggregate glyph/tint

    func test_aggregate_glyph_uniformDelegatesToLeafGlyph() {
        XCTAssertEqual(DirectionVisual.glyph(for: .uniform("---->")), "→")
        XCTAssertEqual(DirectionVisual.glyph(for: .uniform("<----")), "←")
        XCTAssertEqual(DirectionVisual.glyph(for: .uniform("<-?->")), "⚠︎",
                       "uniform conflict — the folder is itself a conflict; user-skip is per-leaf, not aggregate")
        XCTAssertEqual(DirectionVisual.glyph(for: .uniform("<-M->")), "M")
    }

    func test_aggregate_glyph_allUserSkipped() {
        XCTAssertEqual(DirectionVisual.glyph(for: .allUserSkipped), "⊖")
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
}
