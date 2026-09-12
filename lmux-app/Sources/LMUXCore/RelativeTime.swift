import Foundation

/// The app's single relative-time formatter.
///
/// Lists want the compact form ("5m"); sentences want the readable one
/// ("5m ago", "just now"). These used to be two private helpers with their own
/// thresholds and wording.
public enum RelativeTime {
    /// - Parameter sentence: adds " ago" and says "just now" under a minute.
    public static func short(_ unix: Int64, sentence: Bool = false) -> String {
        let seconds = max(Int(Date().timeIntervalSince1970) - Int(unix), 0)
        if seconds < 60 {
            return sentence ? "just now" : "now"
        }
        let suffix = sentence ? " ago" : ""
        if seconds < 3600 { return "\(seconds / 60)m\(suffix)" }
        if seconds < 86400 { return "\(seconds / 3600)h\(suffix)" }
        return "\(seconds / 86400)d\(suffix)"
    }
}
