import SwiftUI

struct ArtifactIcon: View {
    let kind: ArtifactKind
    var size: CGFloat = 24

    var body: some View {
        Image(kind == .rustTarget ? "RustIcon" : "NodeIcon")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(DiskSiftTheme.color(for: kind))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ArtifactRow: View {
    @EnvironmentObject private var model: AppModel
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
                         ?? artifact.kind.folderName)
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
                model.reveal(artifact)
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(artifact.projectName) in Finder")
        }
        .contentShape(Rectangle())
        .padding(.vertical, 11)
    }

    private var createdText: String {
        guard let date = artifact.createdAt else { return "Created unknown" }
        return "Created \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}

private extension String {
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard hasPrefix(home) else { return self }
        return "~" + dropFirst(home.count)
    }
}
