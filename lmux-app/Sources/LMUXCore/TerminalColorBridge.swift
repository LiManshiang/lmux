import Foundation

/// Pure color-bridging helpers shared by the terminal backends.
///
/// lmux stores theme colors as 0...1 doubles (foreground/background/...) and
/// 0...65535 UInt16 triples (ANSI palette). libghostty consumes `#RRGGBB`
/// strings. These conversions are kept dependency-free so they can be unit
/// tested from LMUXCoreTests without linking GhosttyKit.
public enum TerminalColorBridge {
    /// Convert a 0...1 double component to a 2-digit uppercase hex byte.
    public static func hexComponent(_ v: Double) -> String {
        let byte = Int((v * 255).rounded())
        return String(format: "%02X", min(255, max(0, byte)))
    }

    /// Convert a 0...1 RGB tuple to `#RRGGBB`.
    public static func hex(_ rgb: (Double, Double, Double)) -> String {
        "#\(hexComponent(rgb.0))\(hexComponent(rgb.1))\(hexComponent(rgb.2))"
    }

    /// Convert a 0...65535 UInt16 triple to `#RRGGBB`.
    public static func hex(_ rgb: (UInt16, UInt16, UInt16)) -> String {
        let r = rgb.0 >> 8
        let g = rgb.1 >> 8
        let b = rgb.2 >> 8
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
