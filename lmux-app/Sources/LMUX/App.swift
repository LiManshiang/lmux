import SwiftUI
import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the SwiftUI App once the view model exists, so termination can
    /// offer a final manual sync.
    weak var viewModel: ContentViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Only request notification permission when the user hasn't decided yet,
        // so we don't re-prompt on every launch after a denial.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let viewModel, viewModel.hasPinnedSessionsForSync else {
            return .terminateNow
        }

        // Ask before syncing on quit. Defer termination until the (async) sync
        // completes so the export isn't cut off by process exit.
        let alert = NSAlert()
        alert.messageText = "Sync before quitting?"
        alert.informativeText = "You have pinned sessions. Sync them to your shared directory before quitting? This keeps the other machine up to date."
        alert.addButton(withTitle: "Sync & Quit")
        alert.addButton(withTitle: "Quit Without Syncing")
        alert.alertStyle = .warning

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return .terminateNow
        }

        // Defer termination; reply once the export finishes.
        sender.reply(toApplicationShouldTerminate: false)
        Task { @MainActor in
            await viewModel.syncNow()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct LmuxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = ContentViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    appDelegate.viewModel = viewModel
                    viewModel.startBackend()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { viewModel.showNewSessionSheet = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Session") {
                Button("Search Sessions") { viewModel.focusSearch() }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
                Button("Next Session") { viewModel.selectNextSession() }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Previous Session") { viewModel.selectPreviousSession() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button("Stop Session") { viewModel.stopCurrentSession() }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Sync Now") {
                    Task { await viewModel.syncNow() }
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(viewModel.syncInProgress)
                Divider()
                Button("Usage Statistics…") { viewModel.showUsageStats = true }
                Button("Export Sessions…") { viewModel.promptExportSessions() }
                Button("Import Sessions…") { viewModel.promptImportSessions() }
            }
            CommandGroup(replacing: .help) {
                Button("Usage & Shortcuts") { viewModel.showHelp = true }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }

        Settings {
            PreferencesView()
        }
    }
}
