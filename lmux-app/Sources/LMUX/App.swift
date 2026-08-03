import SwiftUI
import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
        }

        Settings {
            PreferencesView()
        }
    }
}
