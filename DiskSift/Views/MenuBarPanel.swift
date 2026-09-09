import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image("BrandMark").resizable().scaledToFit().frame(width: 26, height: 26)
                Text("Hemdiff").font(.headline)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            if let volume = model.volume {
                VStack(alignment: .leading, spacing: 5) {
                    Text(ByteText.compact(volume.availableBytes)).font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("available · \(Int((volume.usedFraction * 100).rounded()))% used").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            metric("Build output", bytes: model.snapshot.artifactBytes, icon: "shippingbox", color: DiskSiftTheme.node)
            metric("Trash estimate", bytes: model.trashSnapshot.bytes, icon: "trash", color: DiskSiftTheme.rust, available: model.trashSnapshot.hasEstimate)
            if !model.trashSnapshot.unavailableRoots.isEmpty { Text("Trash access is restricted").font(.caption).foregroundStyle(.orange) }
            if model.isShowingSetup {
                Text("Finish setup in Hemdiff to start scanning.").font(.caption).foregroundStyle(.secondary)
            } else {
                Button {
                    model.requestQuickCleanup()
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Clean Build Output…", systemImage: "shippingbox")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(DiskSiftTheme.node)
                    .disabled(model.snapshot.artifacts.isEmpty || model.isBusy || model.isReviewingDeletion)
            }
            Divider()
            HStack {
                Button("Open Hemdiff") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }.keyboardShortcut(.defaultAction)
                Spacer()
                Button(model.isScanning ? "Cancel Scan" : "Scan Now") { model.isScanning ? model.cancelScan() : model.startScan() }.disabled(!model.isScanning && (model.isBusy || model.isShowingSetup || model.isReviewingDeletion))
            }
        }.padding(20).frame(width: 330)
    }
    private func metric(_ name: String, bytes: Int64, icon: String, color: Color, available: Bool = true) -> some View {
        HStack {
            Label(name, systemImage: icon).foregroundStyle(color)
            Spacer()
            Text(available ? ByteText.compact(bytes) : "—").fontWeight(.semibold).monospacedDigit()
        }.font(.callout)
    }
}
