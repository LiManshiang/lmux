import AppKit
import Combine

/// Menu bar item showing how many sessions are waiting for input.
///
/// The point is not needing to look at the window: when an agent stops, the
/// count appears up here, and picking a session from the menu jumps straight to
/// it. Without this there was no way to know a background session had stopped
/// until you happened to look at the sidebar.
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()
    private weak var viewModel: ContentViewModel?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        render(count: 0)
    }

    /// Called once the view model exists (it is created by the SwiftUI App).
    func attach(_ viewModel: ContentViewModel) {
        self.viewModel = viewModel
        viewModel.$attentionSessionIds
            .receive(on: RunLoop.main)
            .sink { [weak self] ids in
                self?.render(count: ids.count)
            }
            .store(in: &cancellables)
    }

    private func render(count: Int) {
        guard let button = statusItem.button else { return }
        let name = count > 0 ? "bell.badge.fill" : "bell"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: L("Sessions waiting for input"))
        image?.isTemplate = true
        button.image = image
        // The count rides next to the icon only when there is something to say,
        // so the item stays narrow the rest of the time.
        button.title = count > 0 ? " \(count)" : ""
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
        button.toolTip = count > 0
            ? L("%d session(s) waiting for input", count)
            : L("No sessions waiting")
        button.contentTintColor = count > 0 ? .systemOrange : nil
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let waiting = viewModel?.sessionsNeedingAttention ?? []

        if waiting.isEmpty {
            let item = NSMenuItem(title: L("No sessions waiting"), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for session in waiting {
                let item = NSMenuItem(
                    title: session.name,
                    action: #selector(focusSession(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let showItem = NSMenuItem(title: L("Show lmux"), action: #selector(showApp), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        return menu
    }

    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        viewModel?.revealSession(id: id)
    }

    @objc private func showApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
