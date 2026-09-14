import Foundation

/// Interface strings.
///
/// The English text is the key, so there is no second identifier to keep in
/// sync and a missing translation falls back to English instead of showing a
/// blank or a raw key. A `.lproj` setup would also work, but SwiftPM resource
/// packaging adds a failure mode for no benefit here — the language is chosen
/// inside the app rather than by the system.
///
/// The language is resolved once at launch: switching it takes a relaunch, so
/// the terminal's view tree is never rebuilt underneath a live session.
enum L10n {
    private static let isChinese = AppLanguage.resolved == .chinese

    /// Look up a phrase. Unknown keys fall through to English.
    static func tr(_ key: String) -> String {
        guard isChinese else { return key }
        return zh[key] ?? key
    }

    /// Look up a `String(format:)` pattern and fill it in. Keys that take
    /// arguments use printf placeholders (e.g. "Context %d%%").
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), arguments: args)
    }

    static let zh: [String: String] = [:]
}

/// Shorthand: `L("New Session")` / `L("Context %d%%", percent)`.
func L(_ key: String) -> String { L10n.tr(key) }
func L(_ key: String, _ args: CVarArg...) -> String { L10n.tr(key, args) }
