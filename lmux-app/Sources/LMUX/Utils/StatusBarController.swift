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
    /// Created on first `attach`, never in `init()`.
    ///
    /// `AppDelegate` holds this as a stored property, so `init()` runs during
    /// delegate construction — while the app is still starting and has no
    /// window-server connection yet. `NSStatusBar.statusItem` reaches straight
    /// into that connection, and macOS 12 does not tolerate its absence:
    /// `CGSConnectionByID` asserts and the process aborts on launch
    /// (SIGABRT in `StatusBarController.init` → `NSStatusBar
    /// _statusItemWithLength`). Newer macOS happens to allow the call, which
    /// is why this only ever showed on the Intel/macOS 12 build.
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private weak var viewModel: ContentViewModel?

    /// Called once the view model exists — i.e. from a view that is appearing,
    /// by which point the app is connected and running.
    func attach(_ viewModel: ContentViewModel) {
        self.viewModel = viewModel
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }
        // `attach` can run more than once (the window can be closed and
        // reopened); drop the previous subscription so the item is not
        // rendered once per past appearance.
        cancellables.removeAll()
        viewModel.$attentionSessionIds
            .receive(on: RunLoop.main)
            .sink { [weak self] ids in
                self?.render(count: ids.count)
            }
            .store(in: &cancellables)
        render(count: viewModel.attentionSessionIds.count)
    }

    private func render(count: Int) {
        guard let item = statusItem, let button = item.button else { return }
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
        item.menu = buildMenu()
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
