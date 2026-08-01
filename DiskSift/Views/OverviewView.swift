import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    let openReclaim: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                pageHeader

                if let error = model.errorMessage {
                    StatusMessage(text: error, systemImage: "exclamationmark.triangle.fill", tint: .orange)
                }

                if let notice = model.noticeMessage {
                    StatusMessage(text: notice, systemImage: "checkmark.circle.fill", tint: DiskSiftTheme.node)
                }

                if let volume = model.volume {
                    capacitySection(volume)
                } else {
                    Panel {
                        ProgressView("Reading disk capacity…")
                            .frame(maxWidth: .infinity, minHeight: 140)
                    }
                }

                artifactSection
                locationSection
            }
            .padding(32)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Overview")
    }

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Your disk, in usable terms.")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isSnapshotStale, model.snapshot.finishedAt != .distantPast {
                Label("Inventory is stale", systemImage: "clock.badge.exclamationmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var headerSubtitle: String {
        if model.isScanning {
            return "Refreshing the artifact inventory in the background."
        }
        guard model.snapshot.finishedAt != .distantPast else {
            return "The first artifact scan is starting now."
        }
        return "Artifact inventory updated \(model.snapshot.finishedAt.formatted(.relative(presentation: .named)))."
    }

    private func capacitySection(_ volume: VolumeSnapshot) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(Int((volume.usedFraction * 100).rounded()))%")
                            .font(.system(size: 58, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("used on \(volume.name)")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 168, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(ByteText.string(volume.usedBytes))
                                .font(.title3.weight(.semibold))
                                .monospacedDigit()
                            Text("of \(ByteText.string(volume.totalBytes))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(ByteText.string(volume.availableBytes)) free")
                                .font(.callout.weight(.medium))
                                .monospacedDigit()
                        }

                        StorageRail(
                            volume: volume,
                            rustBytes: model.snapshot.bytes(for: .rustTarget),
                            nodeBytes: model.snapshot.bytes(for: .nodeModules),
                            appleBytes: developerArtifactBytes
                        )

                        StorageLegend(snapshot: model.snapshot, volume: volume)
                    }
                    .padding(.top, 7)
                }

                if let progress = model.scanProgress {
                    Divider()
                    ScanProgressStrip(progress: progress)
                }
            }
        }
    }

    private var artifactSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Regenerable developer storage")
                        .font(.title3.weight(.semibold))
                    Text("\(model.snapshot.artifacts.count) folders · \(ByteText.compact(model.snapshot.artifactBytes)) reclaimable")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.snapshot.artifacts.isEmpty {
                    Button("Review All", action: openReclaim)
                }
            }

            Panel {
                if model.snapshot.artifacts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: model.isScanning ? "magnifyingglass" : "checkmark.seal")
                            .font(.system(size: 28))
                            .foregroundStyle(model.isScanning ? DiskSiftTheme.node : .secondary)
                        Text(model.isScanning ? "Looking for developer artifacts…" : "No developer artifacts found")
                            .font(.headline)
                        Text(model.isScanning
                             ? "You can keep using DiskSift while the inventory is built."
                             : "Add another scan location or run a new scan.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.snapshot.artifacts.prefix(5).enumerated()), id: \.element.id) { index, artifact in
                            ArtifactRow(artifact: artifact)
                            if index < min(4, model.snapshot.artifacts.count - 1) {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Discovered storage groups")
                    .font(.title3.weight(.semibold))
                Text("Known developer bytes grouped by their top-level location—not macOS storage categories.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Panel {
                if model.snapshot.categories.isEmpty {
                    Text("Location totals will appear after the scan completes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                } else {
                    VStack(spacing: 12) {
                        ForEach(model.snapshot.categories.prefix(8)) { category in
                            HStack {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                Text(category.name)
                                    .lineLimit(1)
                                Spacer()
                                Text(ByteText.compact(category.allocatedBytes))
                                    .font(.callout.weight(.semibold))
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
    }

    private var developerArtifactBytes: Int64 {
        model.snapshot.bytes(for: .xcodeDerivedData)
            + model.snapshot.bytes(for: .swiftBuild)
    }
}

private struct ScanProgressStrip: View {
    let progress: ScanProgress

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(progress.entriesVisited.formatted()) entries checked · \(progress.artifactsFound) artifacts found")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                Text(progress.currentPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(ByteText.compact(progress.bytesMeasured))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
