import SwiftUI

struct ArtifactIcon: View {
    let kind: ArtifactKind
    var size: CGFloat = 24

    var body: some View {
        Group {
            switch kind {
            case .rustTarget:
                Image("RustIcon")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            case .nodeModules, .nextBuild:
                Image("NodeIcon")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            case .xcodeDerivedData, .swiftBuild:
                Image(systemName: "hammer")
                    .font(.system(size: size * 0.82, weight: .medium))
            }
        }
        .foregroundStyle(DiskSiftTheme.color(for: kind))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ArtifactRow: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmsCleanup = false
    let artifact: Artifact
    var selectable = false

    var body: some View {
        HStack(spacing: 14) {
            if selectable {
                Button {
                    model.toggleSelection(artifact)
                } label: {
                    Image(systemName: model.selectedArtifactIDs.contains(artifact.id)
                          ? "checkmark.square.fill"
                          : "square")
                        .font(.system(size: 17))
                        .foregroundStyle(
                            model.selectedArtifactIDs.contains(artifact.id)
                                ? DiskSiftTheme.color(for: artifact.kind)
                                : .secondary
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    model.selectedArtifactIDs.contains(artifact.id)
                        ? "Deselect \(artifact.projectName)"
                        : "Select \(artifact.projectName)"
                )
            }

            ArtifactIcon(kind: artifact.kind, size: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(artifact.projectName)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(artifact.worktreeName.map { "\($0) worktree · \(artifact.kind.folderName)" }
                         ?? artifact.kind.title)
                        .font(.caption)
                        .foregroundStyle(DiskSiftTheme.color(for: artifact.kind))
                }
                Text(artifact.projectPath.abbreviatingHome)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 4) {
                Text(ByteText.compact(artifact.allocatedBytes))
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                Text(createdText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                confirmsCleanup = true
            } label: {
                if model.reclaimingArtifactIDs.contains(artifact.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image("ReclaimIcon")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 17, height: 17)
                }
            }
            .buttonStyle(.borderless)
            .disabled(model.isScanning || !model.reclaimingArtifactIDs.isEmpty)
            .help("Permanently delete this folder")
            .accessibilityLabel("Delete \(artifact.kind.title) for \(artifact.projectName)")
        }
        .contentShape(Rectangle())
        .padding(.vertical, 11)
        .confirmationDialog(
            "Delete \(artifact.kind.folderName) for \(artifact.projectName)?",
            isPresented: $confirmsCleanup,
            titleVisibility: .visible
        ) {
            Button("Delete Permanently", role: .destructive) {
                Task { await model.reclaim(artifact) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "\(artifact.path.abbreviatingHome)\n\nDeletion skips Trash and cannot be undone."
            )
        }
    }

    private var createdText: String {
        guard let date = artifact.createdAt else { return "Creation date unknown" }
        return "Created \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}

extension String {
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard hasPrefix(home) else { return self }
        return "~" + dropFirst(home.count)
    }
}
