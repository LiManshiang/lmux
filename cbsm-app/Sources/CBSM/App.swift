import SwiftUI

@main
struct CBSMApp: App {
    @StateObject private var viewModel = ContentViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    viewModel.startBackend()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    viewModel.showNewSessionSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
