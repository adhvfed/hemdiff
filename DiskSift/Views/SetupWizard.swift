import AppKit
import SwiftUI

struct SetupWizard: View {
    @State private var findsProjects = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    private let titles = ["Make room for your next build.", "Choose what to scan.", "Include your Trash."]
    private let icons = ["shippingbox.fill", "folder.badge.plus", "trash.fill"]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("HEMDIFF SETUP").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.setupPage + 1) of 3").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(0..<3) { page in
                    Capsule().fill(page <= model.setupPage ? DiskSiftTheme.node : .secondary.opacity(0.15)).frame(height: 3)
                }
            }.accessibilityHidden(true)
            Group {
                if model.setupPage == 0 { Image("BrandMark").resizable().scaledToFit().padding(8) }
                else { Image(systemName: icons[model.setupPage]).font(.system(size: 32)) }
            }
                .foregroundStyle(DiskSiftTheme.node).frame(width: 68, height: 68)
                .background(DiskSiftTheme.node.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
            Text(titles[model.setupPage]).font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-0.7)
            Group {
                switch model.setupPage {
                case 0: introduction
                case 1: locations
                default: access
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Button("Set Up Later") { model.finishSetup() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.setupPage > 0 { Button("Back") { model.setupPage -= 1 } }
                Button(model.setupPage == 2 ? "Get Started" : "Continue") {
                    if model.setupPage == 2 { model.finishSetup() }
                    else { model.setupPage += 1 }
                }.buttonStyle(.borderedProminent).tint(DiskSiftTheme.node).keyboardShortcut(.defaultAction)
            }
        }
        .padding(32).frame(width: 560, height: 550)
        .background {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [DiskSiftTheme.node.opacity(0.06), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .sheet(isPresented: $findsProjects) { FindProjectsView().environmentObject(model) }
        .task(id: model.setupPage) { if model.setupPage == 2 { await model.refreshTrash() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && model.setupPage == 2 { Task { await model.refreshTrash() } }
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 22) {
            feature("Build output", text: "Find rebuildable folders by project and tool.", icon: "shippingbox")
            feature("Files", text: "Check files across categories, preview, then move to Trash.", icon: "doc.on.doc")
            feature("Trash", text: "See the estimated space to recover before emptying it.", icon: "trash")
            Text("Every deletion asks for confirmation.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var locations: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Hemdiff discovers indexed projects and linked worktrees. Add folders for a complete file inventory.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.scanRoots, id: \.path) { root in
                        HStack {
                            Label(root.path.abbreviatingHome, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.removeScanRoot(root) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Remove \(root.lastPathComponent)")
                        }
                    }
                    if model.scanRoots.isEmpty { Text("No folders added").foregroundStyle(.secondary) }
                }.padding(16)
            }.background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            HStack {
            Button("Find Automatically") { findsProjects = true }.buttonStyle(.borderedProminent).tint(DiskSiftTheme.node)
            Button("Choose Folders…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = true
                panel.prompt = "Add Folders"
                if panel.runModal() == .OK { panel.urls.forEach(model.addScanRoot) }
            }
            }
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Full Disk Access lets Hemdiff measure Trash and show what emptying it could recover. You can continue without it.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Open Full Disk Access.")
                Text("2. Enable Hemdiff. If it’s missing, use + to add it from Applications.")
                Text("3. Reopen Hemdiff if macOS asks.")
            }.font(.callout)
            HStack {
                Button("Open Full Disk Access") { SystemSettings.openFullDiskAccess() }
                Button("Check Again") { Task { await model.refreshTrash() } }.disabled(model.isBusy)
            }
            if model.isLoadingTrash {
                ProgressView("Checking Trash access…").controlSize(.small)
            } else if model.trashSnapshot.measuredAt != .distantPast {
                Label(model.trashSnapshot.unavailableRoots.isEmpty && model.trashSnapshot.errorsSkipped == 0 ? "Trash is accessible" : "Trash access is still restricted",
                      systemImage: model.trashSnapshot.unavailableRoots.isEmpty && model.trashSnapshot.errorsSkipped == 0 ? "checkmark.circle" : "lock")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func feature(_ title: String, text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).foregroundStyle(DiskSiftTheme.node).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
