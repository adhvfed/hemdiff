import AppKit
import SwiftUI

struct TrashView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var order: FileOrder = .size
    private var visible: [ContentItem] { trash.items.filter { search.isEmpty || $0.path.localizedStandardContains(search) }.sorted(by: order.precedes) }
    @State private var checked = Set<String>()
    @State private var focused = Set<String>()
    @State private var confirmation: FileConfirmation?
    @State private var preview: ContentItem?
    private var trash: TrashSnapshot { model.trashSnapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Trash").font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-0.6)
                Spacer()
                Button { Task { await model.refreshTrash() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.isBusy)
                Button("Open in Finder") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")) }
            }
            SpaceHero(title: "Estimated space to recover", bytes: trash.bytes,
                      subtitle: trash.hasEstimate ? "\(trash.items.count.formatted()) \(trash.items.count == 1 ? "item" : "items") in Trash" : "Access needed to measure Trash", color: DiskSiftTheme.rust,
                      isAvailable: trash.hasEstimate)
            ModelMessages()
            if !trash.unavailableRoots.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "lock.shield").font(.title2).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Trash access is restricted").font(.headline)
                        Text("Add Hemdiff in Full Disk Access, enable it, then reopen the app.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Open Full Disk Access") { SystemSettings.openFullDiskAccess() }
                        Button("Show App in Finder") { SystemSettings.revealApplication() }
                    }
                }.padding(18).background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            }
            if model.isLoadingTrash {
                ProgressView("Measuring Trash…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if trash.items.isEmpty {
                ContentUnavailableView(trash.unavailableRoots.isEmpty ? "Trash is empty" : "No accessible items", systemImage: "trash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    ReviewSearchField(placeholder: "Search Trash", text: $search)
                    Picker("Sort", selection: $order) {
                        ForEach(FileOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.frame(width: 145)
                    Button("Check Visible") { checked.formUnion(visible.map(\.path)) }.disabled(visible.isEmpty)
                }
                FileItemTable(items: visible, focused: $focused, checked: checked, toggle: toggle, toggleFocused: {
                    let items = visible.filter { focused.contains($0.path) }
                    let remove = items.allSatisfy { checked.contains($0.path) }
                    for item in items {
                        if remove { checked.remove(item.path) } else { checked.insert(item.path) }
                    }
                }, preview: { preview = $0 })
                Text("Shared blocks and open files can reduce the space recovered.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if trash.errorsSkipped > 0 { Text("\(trash.errorsSkipped) items couldn’t be measured.").font(.caption).foregroundStyle(.orange) }
        }
        .padding(24)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "trash").font(.title2).foregroundStyle(DiskSiftTheme.rust)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(checked.count) checked · \(ByteText.string(trash.items.filter { checked.contains($0.path) }.reduce(0) { $0 + $1.allocatedBytes }))")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                    Text("Deletion from Trash is permanent.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !checked.isEmpty {
                    Button("Clear") { checked.removeAll() }
                    Button("Delete Checked…") { confirmation = FileConfirmation(items: trash.items.filter { checked.contains($0.path) }, permanent: true) }
                        .disabled(model.isBusy)
                }
                Button("Empty Trash…") { confirmation = FileConfirmation(items: trash.items, permanent: true) }
                    .buttonStyle(HemdiffButtonStyle(emphasis: .destructive))
                    .disabled(trash.items.isEmpty || model.isBusy)
            }.padding(.horizontal, 28).padding(.vertical, 18).background(.bar).overlay(alignment: .top) { Divider() }
        }
        .navigationTitle("Trash")
        .task { await model.refreshTrash() }
        .onChange(of: trash.items.map(\.path)) { _, paths in checked.formIntersection(Set(paths)) }
        .sheet(item: $confirmation) { pending in
            FileConfirmationSheet(confirmation: pending) {
                Task { let removed = await model.deleteTrashItems(pending.items); checked.subtract(removed) }
            }
        }
        .sheet(item: $preview) { FilePreview(item: $0) }
    }

    private func toggle(_ item: ContentItem) {
        if checked.contains(item.path) { checked.remove(item.path) } else { checked.insert(item.path) }
    }
}
