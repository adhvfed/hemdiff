import SwiftUI

@main
struct DiskSiftApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("DiskSift", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 720)
        .commands {
            CommandGroup(after: .sidebar) {
                Divider()
                Button(model.isScanning ? "Cancel Scan" : "Scan Now") {
                    model.isScanning ? model.cancelScan() : model.startScan()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(model)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel("DiskSift")
        }
        .menuBarExtraStyle(.window)
    }
}
