import SwiftUI
import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // Only request notification permission when the user hasn't decided yet,
        // so we don't re-prompt on every launch after a denial.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
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
                .onAppear { viewModel.startBackend() }
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
                Button("Export Sessions…") { viewModel.promptExportSessions() }
                Button("Import Sessions…") { viewModel.promptImportSessions() }
            }
        }

        Settings {
            PreferencesView()
        }
    }
}
