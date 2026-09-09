import AppKit
import SwiftUI

private enum ContentSort: String, CaseIterable {
    case size = "Size", modified = "Modified", name = "Name"
}

struct FilesView: View {
    @EnvironmentObject private var model: AppModel
    let openLocations: () -> Void
    @State private var selectedKind: ContentKind?
    @State private var search = ""
    @State private var sort: ContentSort = .size

    private var inventory: ContentInventory { model.snapshot.content }
    private var items: [ContentItem] {
        inventory.summaries
            .filter { selectedKind == nil || $0.kind == selectedKind }
            .flatMap(\.largestItems)
            .filter { search.isEmpty || $0.path.localizedStandardContains(search) }
            .sorted {
                switch sort {
                case .size:
                    return $0.allocatedBytes == $1.allocatedBytes ? $0.path < $1.path : $0.allocatedBytes > $1.allocatedBytes
                case .modified:
                    return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
                case .name:
                    return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                }
            }
    }

    var body: some View {
        GeometryReader { geometry in
            content(compact: geometry.size.width < 740)
        }
    }

    private func content(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Files")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("\(inventory.count.formatted()) items · \(ByteText.string(inventory.allocatedBytes)) on disk")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Scan Locations", action: openLocations)
            }

            if inventory.count == 0 {
                ContentUnavailableView {
                    Label(model.isScanning ? "Scanning…" : "No files scanned", systemImage: "doc")
                } description: {
                    Text("Add a folder such as Downloads, Movies, or Documents in Scan Locations.")
                } actions: {
                    Button("Add a Scan Location", action: openLocations)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    if !compact {
                        ScrollView {
                            VStack(spacing: 3) {
                                categoryButton(nil, title: "All files", icon: "doc.on.doc", bytes: inventory.allocatedBytes)
                                ForEach(inventory.summaries) { summary in
                                    categoryButton(summary.kind, title: summary.kind.title, icon: summary.kind.icon, bytes: summary.allocatedBytes)
                                }
                            }
                        }
                        .frame(width: 205)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        if compact {
                            Picker("Type", selection: $selectedKind) {
                                Text("All files").tag(ContentKind?.none)
                                ForEach(inventory.summaries) { summary in
                                    Text("\(summary.kind.title) · \(ByteText.string(summary.allocatedBytes))")
                                        .tag(Optional(summary.kind))
                                }
                            }
                        }
                        HStack {
                            TextField("Filter largest files", text: $search)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Filter largest files by name or path")
                            Picker("Sort", selection: $sort) {
                                ForEach(ContentSort.allCases, id: \.self) { item in
                                    Text(item.rawValue).tag(item)
                                }
                            }
                            .frame(width: 150)
                        }

                        Table(items) {
                            TableColumn("Name") { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.url.lastPathComponent)
                                        .fontWeight(.medium)
                                        .lineLimit(1)
                                    Text("\(item.kind.title) · \(item.url.deletingLastPathComponent().path.abbreviatingHome)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .help(item.path)
                                .contextMenu {
                                    Button("Show in Finder") { reveal(item) }
                                    Button("Copy Path") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(item.path, forType: .string)
                                    }
                                }
                                .padding(.vertical, 5)
                            }
                            .width(min: 120, ideal: 180, max: .infinity)
                            TableColumn("On disk") { item in
                                Text(ByteText.string(item.allocatedBytes))
                                    .monospacedDigit()
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                            .width(85)
                            TableColumn("Modified") { item in
                                Text(item.modifiedAt?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                                    .foregroundStyle(.secondary)
                            }
                            .width(95)
                            TableColumn("") { item in
                                Button { reveal(item) } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.borderless)
                                .help("Show in Finder")
                                .accessibilityLabel("Show \(item.url.lastPathComponent) in Finder")
                            }
                            .width(28)
                        }
                        .overlay {
                            if items.isEmpty {
                                ContentUnavailableView.search(text: search)
                            }
                        }
                        Text("Largest \(ContentInventory.itemLimitPerKind) items per type · Scan locations only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if inventory.errorsSkipped > 0 {
                Text("\(inventory.errorsSkipped.formatted()) items couldn’t be measured.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(32)
        .navigationTitle("Files")
        .onChange(of: inventory.summaries.map(\.kind)) { _, kinds in
            if let selectedKind, !kinds.contains(selectedKind) { self.selectedKind = nil }
        }
    }

    private func categoryButton(_ kind: ContentKind?, title: String, icon: String, bytes: Int64) -> some View {
        Button {
            selectedKind = kind
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.medium))
                    Text(ByteText.string(bytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedKind == kind ? DiskSiftTheme.node.opacity(0.13) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedKind == kind ? [.isSelected] : [])
    }

    private func reveal(_ item: ContentItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}
