import Foundation

/// Interface language. "system" resolves to Chinese or English from the
/// preferred languages at launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case chinese

    var id: String { rawValue }

    /// Written in the language itself, as is conventional for language pickers
    /// (an English list would say "Chinese", but a reader of Chinese wants 中文).
    var label: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .chinese: return "中文"
        }
    }

    /// The language actually in effect, with "system" resolved.
    ///
    /// Read once at launch (see L10n). Changing it takes a relaunch: making the
    /// text update live would mean rebuilding the view tree, and the terminal's
    /// NSView does not survive that — the session would drop.
    static var resolved: AppLanguage {
        let stored = UserDefaults.standard.string(forKey: "appLanguage") ?? AppLanguage.system.rawValue
        guard let chosen = AppLanguage(rawValue: stored), chosen != .system else {
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? .chinese : .english
        }
        return chosen
    }
}
