import SwiftUI

private enum ArtifactFilter: String, CaseIterable, Identifiable {
    case all
    case rust
    case node

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .rust: "Rust"
        case .node: "Node"
        }
    }
}

private enum ArtifactSort: String, CaseIterable, Identifiable {
    case size
    case created
    case project

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct ReclaimView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: ArtifactFilter = .all
    @State private var sort: ArtifactSort = .size
    @State private var confirmsReclaim = false

    private var visibleArtifacts: [Artifact] {
        let filtered = model.snapshot.artifacts.filter { artifact in
            switch filter {
            case .all: true
            case .rust: artifact.kind == .rustTarget
            case .node: artifact.kind == .nodeModules
            }
        }
        return filtered.sorted { lhs, rhs in
            switch sort {
            case .size:
                lhs.allocatedBytes > rhs.allocatedBytes
            case .created:
                (lhs.createdAt ?? .distantPast) < (rhs.createdAt ?? .distantPast)
            case .project:
                lhs.projectName.localizedStandardCompare(rhs.projectName) == .orderedAscending
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.snapshot.artifacts.isEmpty {
                ContentUnavailableView(
                    "Nothing to reclaim",
                    systemImage: "checkmark.seal",
                    description: Text(
                        model.isScanning
                            ? "A scan is currently looking for project artifacts."
                            : "Run a scan to refresh the inventory."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                artifactList
            }

            selectionBar
        }
        .navigationTitle("Reclaim")
        .confirmationDialog(
            "Move selected folders to Trash?",
            isPresented: $confirmsReclaim,
            titleVisibility: .visible
        ) {
            Button("Move \(model.selectedArtifactIDs.count) to Trash", role: .destructive) {
                Task { await model.reclaimSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will move \(ByteText.compact(model.selectedBytes)) of regenerable build folders to the macOS Trash. No files are permanently deleted."
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose what to reclaim")
                        .font(.system(size: 27, weight: .bold, design: .rounded))
                    Text("Every folder is revalidated before it moves to Trash.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack {
                Picker("Artifact type", selection: $filter) {
                    ForEach(ArtifactFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)

                Spacer()

                Picker("Sort", selection: $sort) {
                    ForEach(ArtifactSort.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .frame(width: 140)

                Button(model.selectedArtifactIDs.isEmpty ? "Select Visible" : "Clear Selection") {
                    if model.selectedArtifactIDs.isEmpty {
                        model.select(visibleArtifacts)
                    } else {
                        model.deselectAll()
                    }
                }
            }
        }
        .padding(32)
        .padding(.bottom, 4)
    }

    private var artifactList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(visibleArtifacts.enumerated()), id: \.element.id) { index, artifact in
                    ArtifactRow(artifact: artifact, selectable: true)
                        .padding(.horizontal, 32)
                        .background(
                            model.selectedArtifactIDs.contains(artifact.id)
                                ? DiskSiftTheme.color(for: artifact.kind).opacity(0.06)
                                : .clear
                        )
                        .onTapGesture {
                            model.toggleSelection(artifact)
                        }
                    if index < visibleArtifacts.count - 1 {
                        Divider()
                            .padding(.leading, 92)
                    }
                }
            }
        }
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                Image("ReclaimIcon")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(model.selectedArtifactIDs.isEmpty ? .secondary : DiskSiftTheme.rust)
                    .frame(width: 25, height: 25)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectionTitle)
                        .font(.callout.weight(.semibold))
                    Text("Folders remain recoverable from Trash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Move to Trash") {
                    confirmsReclaim = true
                }
                .buttonStyle(.borderedProminent)
                .tint(DiskSiftTheme.rust)
                .disabled(model.selectedArtifactIDs.isEmpty)
                .keyboardShortcut(.delete, modifiers: [.command])
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(.bar)
        }
    }

    private var selectionTitle: String {
        guard !model.selectedArtifactIDs.isEmpty else { return "No folders selected" }
        return "\(model.selectedArtifactIDs.count) selected · \(ByteText.compact(model.selectedBytes))"
    }
}
