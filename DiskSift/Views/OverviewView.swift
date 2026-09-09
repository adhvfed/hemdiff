import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    let openReclaim: () -> Void
    let openFiles: () -> Void
    let openTrash: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Storage").font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-0.6)
                    Spacer()
                    if model.isSnapshotStale, model.snapshot.finishedAt != .distantPast {
                        Label("Scan needed", systemImage: "clock").font(.caption).foregroundStyle(.orange)
                    }
                }
                ModelMessages()
                if let volume = model.volume {
                    HStack(spacing: 30) {
                        StorageOrbit(volume: volume, buildBytes: model.snapshot.artifactBytes, trashBytes: model.trashSnapshot.bytes)
                            .frame(width: 180, height: 180)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Available now").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                            Text(ByteText.compact(volume.availableBytes))
                                .font(.system(size: 48, weight: .semibold, design: .rounded)).tracking(-1.8).monospacedDigit()
                            Text("\(ByteText.compact(volume.usedBytes)) used of \(ByteText.compact(volume.totalBytes))")
                                .font(.callout).foregroundStyle(.secondary)
                            Label(volume.name, systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(28).frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 20).fill(.background.secondary)
                        RoundedRectangle(cornerRadius: 20).fill(LinearGradient(colors: [DiskSiftTheme.node.opacity(0.13), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                        RoundedRectangle(cornerRadius: 20).strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
                    }
                }
                if let progress = model.scanProgress {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(progress.summary).font(.callout.weight(.medium))
                            Text(progress.currentPath.abbreviatingHome).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(ByteText.string(progress.bytesMeasured)).font(.callout).monospacedDigit()
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Reclaim space").font(.title3.weight(.semibold))
                    recoveryRow("Build output", subtitle: "\(model.snapshot.artifacts.count) rebuildable folders", bytes: model.snapshot.artifactBytes,
                                icon: "shippingbox.fill", color: DiskSiftTheme.node, action: openReclaim)
                    recoveryRow("Trash", subtitle: model.trashSnapshot.unavailableRoots.isEmpty ? "Estimated recovery after emptying" : "Access needed for a complete estimate",
                                bytes: model.trashSnapshot.bytes, icon: "trash.fill", color: DiskSiftTheme.rust, available: model.trashSnapshot.hasEstimate, action: openTrash)
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Files by type").font(.title3.weight(.semibold))
                        Spacer()
                        Button("Review Files", action: openFiles)
                    }
                    if model.snapshot.content.summaries.isEmpty {
                        Text("Add folders in Scan Locations to classify their files.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 14) {
                            ForEach(model.snapshot.content.summaries.prefix(6)) { summary in
                                Button(action: openFiles) {
                                    HStack(spacing: 12) {
                                        Image(systemName: summary.kind.icon).foregroundStyle(summary.kind.color).frame(width: 24)
                                        Text(summary.kind.title).font(.callout.weight(.medium)).frame(width: 150, alignment: .leading)
                                        GeometryReader { proxy in
                                            Capsule().fill(summary.kind.color.opacity(0.08))
                                            Capsule().fill(summary.kind.color.gradient).frame(width: max(3, proxy.size.width * Double(summary.allocatedBytes) / Double(max(1, model.snapshot.content.allocatedBytes))))
                                        }.frame(height: 6)
                                        Text(ByteText.compact(summary.allocatedBytes)).font(.callout.weight(.medium)).monospacedDigit().frame(width: 90, alignment: .trailing)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }.padding(20).background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .padding(28).frame(maxWidth: 1100).frame(maxWidth: .infinity)
        }.navigationTitle("Storage")
    }

    private func recoveryRow(_ title: String, subtitle: String, bytes: Int64, icon: String, color: Color, available: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 48, height: 48)
                    .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(available ? ByteText.compact(bytes) : "—").font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                Image(systemName: "arrow.up.right").foregroundStyle(color)
            }.padding(18).background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.15), lineWidth: 0.75))
        }.buttonStyle(.plain)
    }
}

private struct StorageOrbit: View {
    let volume: VolumeSnapshot
    let buildBytes: Int64
    let trashBytes: Int64
    private var build: Double { min(volume.usedFraction, Double(buildBytes) / Double(max(1, volume.totalBytes))) }
    private var trash: Double { min(max(0, volume.usedFraction - build), Double(trashBytes) / Double(max(1, volume.totalBytes))) }
    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.06), lineWidth: 20)
            Circle().trim(from: 0, to: volume.usedFraction).stroke(.primary.opacity(0.23), style: StrokeStyle(lineWidth: 20, lineCap: .butt)).rotationEffect(.degrees(-90))
            Circle().trim(from: 0, to: build).stroke(DiskSiftTheme.node.gradient, style: StrokeStyle(lineWidth: 20, lineCap: .butt)).rotationEffect(.degrees(-90))
            Circle().trim(from: build, to: build + trash).stroke(DiskSiftTheme.rust.gradient, style: StrokeStyle(lineWidth: 20, lineCap: .butt)).rotationEffect(.degrees(-90))
            Circle().stroke(.separator.opacity(0.25), lineWidth: 1).padding(20)
            VStack(spacing: 3) {
                Text("\(Int((volume.usedFraction * 100).rounded()))%")
                    .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("used").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int((volume.usedFraction * 100).rounded())) percent used. Teal is build output; orange is Trash.")
    }
}
