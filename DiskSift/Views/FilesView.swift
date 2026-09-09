import AppKit
import SwiftUI

struct FilesView: View {
    @EnvironmentObject private var model: AppModel
    let openLocations: () -> Void
    @StateObject private var review = FileReviewModel()
    @State private var confirmation: FileConfirmation?
    @State private var preview: ContentItem?
    @State private var checkedOnly = false

    private var inventory: ContentInventory { model.snapshot.content }
    private var queryKey: String { "\(model.contentRevision)|\(inventory.indexPath ?? "")|\(review.kinds.map(\.rawValue).sorted())|\(review.search)|\(review.order.rawValue)" }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Files").font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-0.6)
                    Text("\(inventory.count.formatted()) items · \(ByteText.string(inventory.allocatedBytes))")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Scan Locations", action: openLocations)
                }
                ModelMessages()
                if let error = review.error { StatusMessage(text: error, systemImage: "exclamationmark.triangle", tint: .orange) }
                if inventory.count == 0 {
                    ContentUnavailableView("No files scanned", systemImage: "doc.on.doc", description: Text("Add a folder in Scan Locations, then scan."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(alignment: .top, spacing: 20) {
                        if geometry.size.width > 760 { categoryList.frame(width: 190) }
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                if geometry.size.width <= 760 {
                                    Menu {
                                        Button("All categories") { review.kinds = [] }
                                        ForEach(inventory.summaries) { summary in
                                            Toggle(summary.kind.title, isOn: categoryBinding(summary.kind))
                                        }
                                    } label: { Label("Types", systemImage: "line.3.horizontal.decrease") }
                                }
                                TextField("Filter files by name or path", text: $review.search).textFieldStyle(.roundedBorder)
                                Picker("Sort", selection: $review.order) {
                                    ForEach(FileOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }.frame(width: 140)
                            }
                            FileItemTable(items: checkedOnly ? review.checkedItems : review.items,
                                          focused: $review.focused, checked: Set(review.checked.keys),
                                          toggle: review.toggle, toggleFocused: toggleFocused,
                                          preview: { preview = $0 }, compact: geometry.size.width <= 760)
                                .overlay {
                                    if review.isLoading { ProgressView().padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) }
                                    else if !checkedOnly && review.items.isEmpty { ContentUnavailableView.search(text: review.search) }
                                }
                            HStack(spacing: 10) {
                                Text(checkedOnly ? "\(review.checked.count) checked items" : "\(review.count == 0 ? 0 : review.offset + 1)–\(min(review.offset + review.pageSize, review.count)) of \(review.count.formatted())")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                Spacer()
                                Button { Task { await review.load(inventory, offset: max(0, review.offset - review.pageSize)) } } label: { Image(systemName: "chevron.left") }
                                    .disabled(checkedOnly || review.offset == 0 || review.isLoading).help("Previous page")
                                Button { Task { await review.load(inventory, offset: review.offset + review.pageSize) } } label: { Image(systemName: "chevron.right") }
                                    .disabled(checkedOnly || review.offset + review.pageSize >= review.count || review.isLoading).help("Next page")
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { selectionTray }
        .navigationTitle("Files")
        .task(id: queryKey) { await review.load(inventory) }
        .sheet(item: $confirmation) { pending in
            FileConfirmationSheet(confirmation: pending) {
                Task {
                    let moved = await model.trashFiles(pending.items)
                    review.removeChecked(moved)
                    await review.load(model.snapshot.content)
                }
            }
        }
        .sheet(item: $preview) { FilePreview(item: $0) }
    }

    private var categoryList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Button { review.kinds = [] } label: {
                    HStack {
                        Image(systemName: review.kinds.isEmpty ? "checkmark.square.fill" : "square")
                        Text("All categories").font(.callout.weight(.medium))
                        Spacer()
                    }.padding(12).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(DiskSiftTheme.node)
                ForEach(inventory.summaries) { summary in
                    Button {
                        if review.kinds.contains(summary.kind) { review.kinds.remove(summary.kind) }
                        else { review.kinds.insert(summary.kind) }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: review.kinds.contains(summary.kind) ? "checkmark.square.fill" : summary.kind.icon)
                                .foregroundStyle(summary.kind.color).frame(width: 18).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(summary.kind.title).font(.callout.weight(.medium))
                                Text(ByteText.string(summary.allocatedBytes)).font(.caption).foregroundStyle(.secondary)
                                GeometryReader { proxy in
                                    Capsule().fill(summary.kind.color.opacity(0.12))
                                    Capsule().fill(summary.kind.color).frame(width: max(2, proxy.size.width * Double(summary.allocatedBytes) / Double(max(1, inventory.allocatedBytes))))
                                }.frame(height: 3)
                            }
                            Spacer(minLength: 0)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(review.kinds.contains(summary.kind) ? summary.kind.color.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(review.kinds.contains(summary.kind) ? [.isSelected] : [])
                }
            }
        }
    }

    private var selectionTray: some View {
        HStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(DiskSiftTheme.node)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(review.checked.count) checked · \(ByteText.string(review.checkedBytes))").font(.callout.weight(.semibold)).monospacedDigit()
                Text("↑ ↓ to navigate · Space to check · ⌘Y to preview").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Check This Page") { review.checkPage() }.disabled(checkedOnly)
                Button("Clear Checked") { review.clear() }
                Toggle("Show Checked Only", isOn: $checkedOnly)
                Button("Preview Focused File") {
                    if let item = (checkedOnly ? review.checkedItems : review.items).first(where: { review.focused.contains($0.path) }) { preview = item }
                }.keyboardShortcut("y", modifiers: .command)
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28)
            Button("Move to Trash…") { confirmation = FileConfirmation(items: review.checkedItems, permanent: false) }
                .buttonStyle(.borderedProminent).tint(DiskSiftTheme.node)
                .disabled(review.checked.isEmpty || model.isBusy)
                .keyboardShortcut(.delete, modifiers: .command)
        }
        .padding(.horizontal, 28).padding(.vertical, 18)
        .background(.bar).overlay(alignment: .top) { Divider() }
    }

    private func categoryBinding(_ kind: ContentKind) -> Binding<Bool> {
        Binding(get: { review.kinds.contains(kind) }, set: { value in
            if value { review.kinds.insert(kind) } else { review.kinds.remove(kind) }
        })
    }
    private func toggleFocused() {
        if checkedOnly {
            for item in review.checkedItems where review.focused.contains(item.path) { review.toggle(item) }
        } else { review.toggleFocused() }
    }
}
