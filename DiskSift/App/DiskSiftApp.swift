import SwiftUI

@main
struct DiskSiftApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBar
    @AppStorage("showsMenuBarExtra") private var showsMenuBarExtra = true

    var body: some Scene {
        WindowGroup("Hemdiff", id: "main") {
            RootView()
                .environmentObject(model)
                .background(MenuBarInstaller(controller: menuBar, model: model))
                .frame(minWidth: 780, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            SetupCommands(model: model)
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .sidebar) {
                Divider()
                Toggle("Show Menu Bar Icon", isOn: $showsMenuBarExtra)
                Button(model.isScanning ? "Cancel Scan" : "Scan Now") {
                    model.isScanning ? model.cancelScan() : model.startScan()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

    }
}

private struct SetupCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Run Setup Wizard…") {
                MainWindow.show(using: openWindow)
                model.showSetup()
            }.disabled(model.isReviewingDeletion || model.isManagingFiles || !model.reclaimingArtifactIDs.isEmpty)
        }
    }
}
