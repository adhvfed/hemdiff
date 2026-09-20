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
        diagnose("init")
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
        diagnose("install")
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
            // An unpositioned item goes to the far left and can disappear behind
            // the camera housing on crowded menu bars. Seed only the first placement;
            // subsequent launches preserve the user's Command-dragged position.
            let positionKey = "NSStatusItem Preferred Position \(autosaveName)"
            if defaults.object(forKey: positionKey) == nil {
                defaults.set(0, forKey: positionKey)
            }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.diagnose("visible") }
    }

    private func diagnose(_ phase: String) {
        guard let path = ProcessInfo.processInfo.environment["HEMDIFF_MENU_DIAGNOSTICS"] else { return }
        let data: [String: Any] = [
            "phase": phase, "pid": ProcessInfo.processInfo.processIdentifier,
            "item": statusItem != nil, "visible": statusItem?.isVisible ?? false,
            "length": statusItem?.length ?? 0,
            "button": statusItem?.button.map { NSStringFromRect($0.frame) } ?? "",
            "window": statusItem?.button?.window.map { NSStringFromRect($0.frame) } ?? "",
            "windowVisible": statusItem?.button?.window?.isVisible ?? false,
            "image": statusItem?.button?.image.map { NSStringFromSize($0.size) } ?? "",
            "screens": phase == "init" ? [] : NSScreen.screens.map { NSStringFromRect($0.frame) },
            "rightAreas": phase == "init" ? [] : NSScreen.screens.map { $0.auxiliaryTopRightArea.map(NSStringFromRect) ?? "" },
            "occlusion": statusItem?.button?.window?.occlusionState.rawValue ?? 0
        ]
        guard var record = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) else { return }
        record.append(10)
        let url = URL(fileURLWithPath: path)
        var existing = (try? Data(contentsOf: url)) ?? Data()
        existing.append(record)
        try? existing.write(to: url, options: .atomic)
        if phase == "visible", let button = statusItem?.button,
           let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) {
            button.cacheDisplay(in: button.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".png"))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updateVisibility()
    }

    @objc private func togglePanel() {
        guard let button = statusItem?.button else { return }
        guard popover.contentViewController != nil else {
            NSApp.activate(ignoringOtherApps: true)
            MainWindow.existing()?.makeKeyAndOrderFront(nil)
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
                MainWindow.show(using: openWindow)
            }
        }
    }
}

enum MenuBarIcon {
    static var image: NSImage {
        let source = NSImage(named: "MenuBarIcon") ??
            NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Hemdiff")!
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        // Materialize correctly sized representations. Changing an asset's logical
        // size alone leaves its original 100px vector representation attached.
        for scale in [1, 2] {
            let pixels = 22 * scale
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
            NSGraphicsContext.restoreGraphicsState()
            bitmap.size = size
            image.addRepresentation(bitmap)
        }
        image.isTemplate = true
        return image
    }
}


/// Reuse the open main window instead of opening another one.
/// Its title follows the selected destination, so only the window itself identifies it.
@MainActor
enum MainWindow {
    private static let tracked = NSHashTable<NSWindow>.weakObjects()

    static func track(_ window: NSWindow) {
        tracked.add(window)
    }

    /// NSApp drops a closed window, so a tracked window listed there is still open.
    static func existing() -> NSWindow? {
        existing(among: NSApp.windows)
    }

    static func existing(among windows: [NSWindow]) -> NSWindow? {
        windows.first { tracked.contains($0) && $0.canBecomeMain }
    }

    static func show(using openWindow: OpenWindowAction) {
        if let window = existing() {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Report the hosting window of the main scene to MainWindow.
struct MainWindowTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { TrackingView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class TrackingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainWindow.track(window) }
        }
    }
}
