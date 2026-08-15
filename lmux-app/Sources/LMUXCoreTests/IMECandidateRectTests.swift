import XCTest
@testable import LMUXCore

final class IMECandidateRectTests: XCTestCase {
    // MARK: - Basic conversion

    func testConvertsTopLeftOriginToBottomLeft() {
        // Caret on the first row (y=0 top-left) of a 100pt-tall view.
        let point = IMECandidateRect.ImePoint(x: 5, y: 0, width: 0, height: 16)
        let rect = IMECandidateRect.anchorRect(for: point, viewWidth: 300, viewHeight: 100)
        // Bottom-left y = 100 - 0 - 16 = 84; anchored one cell above = 84 + 16 = 100.
        XCTAssertEqual(rect.x, 5, accuracy: 0.001)
        XCTAssertEqual(rect.y, 100, accuracy: 0.001)
        XCTAssertEqual(rect.height, 16, accuracy: 0.001)
    }

    func testCaretOnLastRowStaysInsideView() {
        // Caret on the last row: top-left y = 100 - 16 = 84 (16pt cell).
        // Old code produced a negative y (84 + 16 = 100 > view height 100 →
        // bottom-left y = 100 - 84 - 16 = 0); anchoring above gives 16, fine.
        let point = IMECandidateRect.ImePoint(x: 5, y: 84, width: 0, height: 16)
        let rect = IMECandidateRect.anchorRect(for: point, viewWidth: 300, viewHeight: 100)
        XCTAssertGreaterThanOrEqual(rect.y, 0, "candidate rect must never go off-screen")
        XCTAssertLessThanOrEqual(rect.y + rect.height, 100 + 0.001)
    }

    func testCaretNearTopIsClampedToZero() {
        // Caret near the top (y=2 top-left). Bottom-left y = 100 - 2 - 16 = 82;
        // anchored above = 98, still inside.
        let point = IMECandidateRect.ImePoint(x: 10, y: 2, width: 0, height: 16)
        let rect = IMECandidateRect.anchorRect(for: point, viewWidth: 200, viewHeight: 100)
        XCTAssertGreaterThanOrEqual(rect.y, 0)
    }

    func testCaretAtVeryTopClamps() {
        // Caret exactly at top of a one-row view. Anchoring above the caret
        // lands at the very top edge (y == viewHeight) — never negative, and
        // the input method flips the candidate list below in that case.
        let point = IMECandidateRect.ImePoint(x: 0, y: 0, width: 0, height: 8)
        let rect = IMECandidateRect.anchorRect(for: point, viewWidth: 100, viewHeight: 8)
        XCTAssertGreaterThanOrEqual(rect.y, 0, "clamp must never produce a negative origin")
        XCTAssertLessThanOrEqual(rect.y, 8 + 0.001, "rect must stay within the view")
    }

    // MARK: - Minimum width

    func testZeroWidthGetsMinimum() {
        let point = IMECandidateRect.ImePoint(x: 20, y: 50, width: 0, height: 16)
        let rect = IMECandidateRect.anchorRect(for: point, viewWidth: 300, viewHeight: 200)
        XCTAssertEqual(rect.width, 16, accuracy: 0.001)
    }

    func testExistingWidthIsPreserved() {
        let point = IMECandidateRect.ImePoint(x: 20, y: 50, width: 100, height: 16)
        let rect = IMECandidateRect.anchorRect(for: point, viewWidth: 300, viewHeight: 200)
        XCTAssertEqual(rect.width, 100, accuracy: 0.001)
    }

    func testCustomMinimumWidth() {
        let point = IMECandidateRect.ImePoint(x: 20, y: 50, width: 0, height: 16)
        let rect = IMECandidateRect.anchorRect(for: point, viewWidth: 300, viewHeight: 200, minimumWidth: 24)
        XCTAssertEqual(rect.width, 24, accuracy: 0.001)
    }

    // MARK: - Regression: candidate must sit ABOVE the preedit

    func testAnchoredOneCellAboveCaret() {
        // Caret on row 5 of 8-pt cells, view 80pt tall (10 rows).
        // top-left y = 5 * 8 = 40.
        let point = IMECandidateRect.ImePoint(x: 0, y: 40, width: 0, height: 8)
        let rect = IMECandidateRect.anchorRect(for: point, viewWidth: 200, viewHeight: 80)
        // Bottom-left caret bottom = 80 - 40 - 8 = 32.
        // Anchor rect y = 32 + 8 = 40 → one full cell above the caret.
        XCTAssertEqual(rect.y, 40, accuracy: 0.001)
        XCTAssertGreaterThan(rect.y, 32, "candidate must sit above the preedit, not overlap it")
    }
}
