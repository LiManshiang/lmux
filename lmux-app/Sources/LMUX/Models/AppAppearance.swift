import AppKit

/// The window appearance the user picked. `system` follows macOS.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Follow System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil hands the decision back to macOS.
    private var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Applies the choice to every window at once.
    ///
    /// The main window, the settings window and any session windows are all
    /// AppKit windows, so setting it on NSApp is both the simplest and the most
    /// complete route — SwiftUI's preferredColorScheme would only cover the
    /// scenes it is attached to.
    static func apply(rawValue: String) {
        NSApp.appearance = (AppAppearance(rawValue: rawValue) ?? .system).nsAppearance
    }
}
