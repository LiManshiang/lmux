import Foundation

/// Geometry for positioning the IME candidate window relative to a terminal's
/// inline preedit text.
///
/// Ghostty's `ghostty_surface_ime_point` reports the caret cell in a top-left
/// origin (y grows downward), while AppKit's `firstRect(forCharacterRange:)`
/// must return a bottom-left origin rect (y grows upward). The inline preedit
/// (composing pinyin) is drawn AT the caret cell, so the candidate window must
/// be anchored one cell above the caret — otherwise it overlaps the pinyin.
/// The rect is clamped inside the view and given a minimum width so the input
/// method never anchors the candidate list off-screen or on top of the
/// composing text.
public enum IMECandidateRect {
    /// A point in a top-left-origin coordinate system (Ghostty ime point).
    public struct ImePoint {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// A rect in a bottom-left-origin coordinate system (AppKit view rect).
    public struct Rect {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Convert a Ghostty ime point to an AppKit candidate-anchor rect.
    ///
    /// - Parameters:
    ///   - point: caret cell in top-left origin (y grows downward).
    ///   - viewWidth: width of the terminal view.
    ///   - viewHeight: height of the terminal view.
    ///   - minimumWidth: minimum anchor width (defaults to one cell width).
    /// - Returns: rect in bottom-left origin (y grows upward), anchored one
    ///   cell above the caret and clamped inside the view.
    public static func anchorRect(
        for point: ImePoint,
        viewWidth: Double,
        viewHeight: Double,
        minimumWidth: Double = 16
    ) -> Rect {
        // Bottom-left origin: the caret's bottom edge from the view bottom.
        let caretBottomY = viewHeight - point.y - point.height
        // Anchor one full cell ABOVE the caret so the candidate list clears
        // the inline preedit. Clamp to 0 so a caret near the top never pushes
        // the rect off-screen (the input method then flips the list below).
        let y = max(0, caretBottomY + point.height)
        // Ghostty reports the caret (zero width); give the anchor a minimum
        // width so the candidate window offsets next to the preedit.
        let width = max(point.width, minimumWidth)
        return Rect(x: point.x, y: y, width: width, height: point.height)
    }
}
