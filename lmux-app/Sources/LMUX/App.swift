import SwiftUI
import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the SwiftUI App once the view model exists, so termination can
    /// offer a final manual sync.
    weak var viewModel: ContentViewModel?

    /// Guards the terminate reply so only the first (sync-done or timeout)
    /// reply reaches AppKit.
    private var didReplyToTerminate = false

    /// Non-modal progress panel shown while the final sync runs on quit, so
    /// the user knows the app is finishing, not hung.
    private var syncPanel: NSPanel?

    private func replyToTerminate(_ sender: NSApplication, shouldTerminate: Bool) {
        hideSyncPanel()
        guard !didReplyToTerminate else { return }
        didReplyToTerminate = true
        sender.reply(toApplicationShouldTerminate: shouldTerminate)
    }

    private func showSyncPanel() {
        hideSyncPanel()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 84),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Sync & Quit"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        let label = NSTextField(labelWithString: "Synchronizing sessions before quitting…")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        syncPanel = panel
    }

    private func hideSyncPanel() {
        syncPanel?.close()
        syncPanel = nil
    }

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
        // NSAlert lays buttons out right-to-left: first addButton is the
        // rightmost (default, Return key). Sync & Quit stays the default;
        // Cancel sits on the far left but is always visible.
        alert.addButton(withTitle: "Sync & Quit")
        alert.addButton(withTitle: "Quit Without Syncing")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        if response == .alertThirdButtonReturn {
            // Cancel: stay running, no sync.
            return .terminateCancel
        }
        guard response == .alertFirstButtonReturn else {
            return .terminateNow
        }

        // Defer termination; reply with true once the export finishes.
        // (Do NOT call reply(false) here — that cancels the termination and
        // the later reply(true) is ignored, leaving the app running.)
        // Show a progress panel so the quit doesn't look like a hang, and cap
        // the sync so the app quits even if a sync request hangs.
        showSyncPanel()
        let syncTask = Task { @MainActor in
            _ = await viewModel.syncNow()
            replyToTerminate(sender, shouldTerminate: true)
        }
        Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s cap
            syncTask.cancel()
            replyToTerminate(sender, shouldTerminate: true)
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
                    Task {
                        let result = await viewModel.syncNow()
                        viewModel.reportSyncResult(result)
                    }
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
            // The Settings window is a separate scene: environmentObject
            // values from the WindowGroup do NOT propagate here. SyncSettings
            // reads the shared ContentViewModel via @EnvironmentObject, so it
            // must be injected explicitly — otherwise opening the Sync pane
            // crashes with EXC_BAD_INSTRUCTION (EnvironmentObject.error()).
            PreferencesView()
                .environmentObject(viewModel)
        }
    }
}
