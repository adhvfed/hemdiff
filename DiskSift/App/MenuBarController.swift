import AppKit
import Combine
import SwiftUI

/// Own the native status item for the lifetime of the app, independently of windows.
@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private(set) var statusItem: NSStatusItem?
    private let defaults: UserDefaults
    private let autosaveName: String
    private let popover = NSPopover()
    private var defaultsObservation: AnyCancellable?
    private var openMainWindow: (() -> Void)?

    override convenience init() {
        self.init(defaults: .standard, autosaveName: "HemdiffQuickActions")
    }

    init(defaults: UserDefaults, autosaveName: String) {
        self.defaults = defaults
        self.autosaveName = autosaveName
        super.init()
    }

    func install(model: AppModel, openMainWindow: @escaping () -> Void) {
        self.openMainWindow = openMainWindow
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView:
            MenuBarPanel(openMainWindow: { [weak self] in
                self?.popover.performClose(nil)
                self?.openMainWindow?()
            }).environmentObject(model)
        )
        updateVisibility()
        if defaultsObservation == nil {
            defaultsObservation = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.updateVisibility() }
        }
    }

    func updateVisibility() {
        let visible = defaults.object(forKey: "showsMenuBarExtra") == nil || defaults.bool(forKey: "showsMenuBarExtra")
        if !visible {
            removeStatusItem()
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.autosaveName = autosaveName
            if let button = item.button {
                button.image = MenuBarIcon.image
                button.imagePosition = .imageOnly
                button.imageScaling = .scaleProportionallyDown
                button.toolTip = "Hemdiff — scan and clean build output"
                button.setAccessibilityLabel("Hemdiff")
                button.target = self
                button.action = #selector(togglePanel)
            }
            statusItem = item
        }
        // Explicit preference wins over any stale native visibility restoration.
        if statusItem?.isVisible != true { statusItem?.isVisible = true }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateVisibility()
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        guard popover.contentViewController != nil else {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.title == "Hemdiff" }?.makeKeyAndOrderFront(nil)
            return
        }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    func removeStatusItem() {
        popover.performClose(nil)
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
        statusItem = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        defaultsObservation?.cancel()
        removeStatusItem()
    }
}

/// Capture the SwiftUI window action once, then keep quick actions working after closure.
struct MenuBarInstaller: View {
    let controller: MenuBarController
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear {
            controller.install(model: model) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

enum MenuBarIcon {
    static var image: NSImage {
        let image = (NSImage(named: "MenuBarIcon")?.copy() as? NSImage) ??
            NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Hemdiff")!
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = true
        return image
    }
}
