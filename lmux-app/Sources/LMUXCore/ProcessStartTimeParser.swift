import Foundation

/// Parses the `ps -o lstart=` output format used by agent detection.
///
/// ps emits a locale-dependent date. Under a zh_CN system it can print
/// "六  8月/15 16:58:33 2026", which a date format with English month/day
/// names cannot parse. Callers must force C locale (LC_ALL=C) on the ps
/// invocation; this parser then reliably handles the English form and the
/// trailing-tab variant some ps versions emit.
public enum ProcessStartTimeParser {
    /// Parse a `ps -o lstart=` line into a date, or nil when unparseable.
    public static func parse(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        if let date = formatter.date(from: text) {
            return date
        }
        // Some ps versions emit a trailing tab after the year.
        let alt = text.replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return formatter.date(from: alt)
    }
}
