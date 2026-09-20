import AppKit
import SwiftUI

struct FilesView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var review: FileReviewModel
    let openLocations: () -> Void
    @State private var confirmation: FileConfirmation?
    @State private var preview: ContentItem?
    @State private var checkedOnly = false
    @State private var showInspector = true
    private var focusedItem: ContentItem? {
        (checkedOnly ? review.checkedItems : review.items).first { review.focused.contains($0.path) }
    }

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
                    if geometry.size.width > 1050 {
                        Toggle(isOn: $showInspector) { Image(systemName: "sidebar.right") }
                            .toggleStyle(.button).help("Show preview inspector")
                    } else {
                        Button { preview = focusedItem } label: { Image(systemName: "eye") }
                            .disabled(focusedItem == nil).help("Preview selected file")
                    }
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
                                ReviewSearchField(placeholder: "Search name or path", text: $review.search)
                                Picker("Sort", selection: $review.order) {
                                    ForEach(FileOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                                }.frame(width: 140)
                            }
                            FileItemTable(items: checkedOnly ? review.checkedItems : review.items,
                                          focused: $review.focused, checked: Set(review.checked.keys),
                                          toggle: review.toggle, toggleFocused: toggleFocused,
                                          preview: { preview = $0 }, compact: geometry.size.width <= 1050, protection: review.protection,
                                          checkProtection: { item in Task { await review.checkProtection(item) } })
                                .overlay {
                                    if review.isLoading || review.isVerifyingProtection { ProgressView().padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) }
                                    else if !checkedOnly && review.items.isEmpty { ContentUnavailableView.search(text: review.search) }
                                }
                            HStack(spacing: 10) {
                                Text(checkedOnly ? "\(review.checked.count) checked" : "\(review.count == 0 ? 0 : review.offset + 1)–\(min(review.offset + review.pageSize, review.count)) of \(review.count.formatted())")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                Spacer()
                                Button { Task { await review.load(inventory, offset: max(0, review.offset - review.pageSize)) } } label: { Image(systemName: "chevron.left") }
                                    .disabled(checkedOnly || review.offset == 0 || review.isLoading).help("Previous page")
                                Button { Task { await review.load(inventory, offset: review.offset + review.pageSize) } } label: { Image(systemName: "chevron.right") }
                                    .disabled(checkedOnly || review.offset + review.pageSize >= review.count || review.isLoading).help("Next page")
                            }
                        }
                        if showInspector, geometry.size.width > 1050, let item = focusedItem {
                            FileInspector(item: item, protection: review.protection[item.path],
                                          checked: review.checked[item.path] != nil,
                                          toggle: { review.toggle(item) }, expand: { preview = item },
                                          checkProtection: { Task { await review.checkProtection(item) } })
                        }
                    }
                }
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { selectionTray }
        .navigationTitle("Files")
        .background {
            Button("Preview Selected File") { preview = focusedItem }
                .keyboardShortcut("y", modifiers: .command).disabled(focusedItem == nil).hidden()
        }
        .onChange(of: review.checked.isEmpty) { _, empty in if empty { checkedOnly = false } }
        .task(id: queryKey) {
            if !review.search.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled else { return }
            await review.load(inventory)
        }

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
            VStack(alignment: .leading, spacing: 3) {
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
                            VStack(alignment: .leading, spacing: 3) {
                                Text(summary.kind.title).font(.callout.weight(.medium))
                                Text(ByteText.string(summary.allocatedBytes)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(review.kinds.contains(summary.kind) ? summary.kind.color.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(review.kinds.contains(summary.kind) ? [.isSelected] : [])
                }
            }
        }
    }

    private var selectionTray: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                selectionSummary.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 12)
                selectionActions.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 12) {
                selectionSummary
                HStack { Spacer(); selectionActions }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(.bar).overlay(alignment: .top) { Divider() }
    }

    private var selectionSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(DiskSiftTheme.node)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(review.checked.count) checked · \(ByteText.string(review.checkedBytes))").font(.callout.weight(.semibold)).monospacedDigit()
                Text("↑ ↓ navigate · Space check · ⌘Y preview · Git-tracked files protected").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var selectionActions: some View {
        HStack(spacing: 10) {
            if !review.checked.isEmpty {
                Toggle("Checked only", isOn: $checkedOnly).toggleStyle(.button)
                Button("Clear") { review.clear() }.help("Uncheck all files")
            }
            Menu {
                Button("Check This Page") { review.checkPage() }.disabled(checkedOnly || review.isVerifyingProtection)
                Button("Clear Checked") { review.clear() }
                Toggle("Show Checked Only", isOn: $checkedOnly)
                Button("Preview Focused File") {
                    if let item = (checkedOnly ? review.checkedItems : review.items).first(where: { review.focused.contains($0.path) }) { preview = item }
                }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28)
            Button("Move to Trash…") { confirmation = FileConfirmation(items: review.checkedItems, permanent: false) }
                .buttonStyle(HemdiffButtonStyle(emphasis: .primary)).tint(DiskSiftTheme.node)
                .disabled(review.checked.isEmpty || model.isBusy)
                .keyboardShortcut(.delete, modifiers: .command)
        }
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
