import SwiftUI

@main
struct DiskSiftApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("showsMenuBarExtra") private var showsMenuBarExtra = true

    var body: some Scene {
        Window("Hemdiff", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            SetupCommands(model: model)
            CommandGroup(after: .sidebar) {
                Divider()
                Toggle("Show Menu Bar Icon", isOn: $showsMenuBarExtra)
                Button(model.isScanning ? "Cancel Scan" : "Scan Now") {
                    model.isScanning ? model.cancelScan() : model.startScan()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra(isInserted: $showsMenuBarExtra) {
            MenuBarPanel()
                .environmentObject(model)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .renderingMode(.template)
                .accessibilityLabel("Hemdiff")
        }
        .menuBarExtraStyle(.window)
    }
}

private struct SetupCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Run Setup Wizard…") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                model.showSetup()
            }.disabled(model.isReviewingDeletion || model.isManagingFiles || !model.reclaimingArtifactIDs.isEmpty)
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
