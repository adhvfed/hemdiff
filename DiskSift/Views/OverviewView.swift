import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel
    let openReclaim: () -> Void
    let openFiles: (ContentKind?) -> Void
    let openTrash: () -> Void
    var openFile: ((ContentItem) -> Void)? = nil

    private var largest: [ContentItem] {
        Array(model.snapshot.content.summaries.flatMap(\.largestItems)
            .sorted { FileOrder.size.precedes($0, $1) }.prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                capacityHeader
                ModelMessages()
                if let progress = model.scanProgress {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(progress.summary).font(.callout.weight(.medium))
                            Text(progress.currentPath.abbreviatingHome).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(ByteText.compact(progress.bytesMeasured)).font(.callout).monospacedDigit()
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    recoveryCard("Build output", subtitle: "\(model.snapshot.artifacts.count) folders · Can be rebuilt",
                                 bytes: model.snapshot.artifactBytes, icon: "shippingbox", color: DiskSiftTheme.node, action: openReclaim)
                    recoveryCard("Trash", subtitle: model.trashSnapshot.hasEstimate ? "\(model.trashSnapshot.items.count) items · Empty to reclaim" : "Allow access to measure",
                                 bytes: model.trashSnapshot.bytes, icon: "trash", color: DiskSiftTheme.rust,
                                 available: model.trashSnapshot.hasEstimate, action: openTrash)
                }
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Files").font(.title3.weight(.semibold))
                        Text("\(ByteText.compact(model.snapshot.content.allocatedBytes)) in scanned folders")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Browse Largest") { openFiles(nil) }.disabled(model.snapshot.content.count == 0)
                    }
                    if model.snapshot.content.summaries.isEmpty {
                        HStack {
                            Text(model.isScanning ? "Measuring files…" : "Scan folders to find large files.")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("Choose Folders…") { model.destination = .locations }
                        }.padding(20).background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 20) {
                                typeBreakdown.frame(minWidth: 280, maxWidth: .infinity)
                                largestFiles.frame(width: 270)
                            }
                            VStack(alignment: .leading, spacing: 20) {
                                largestFiles
                                typeBreakdown
                            }
                        }
                    }
                }
            }.padding(24).frame(maxWidth: .infinity)
        }.navigationTitle("")
    }

    private var capacityHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    if let volume = model.volume {
                        Label(volume.name, systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(ByteText.compact(volume.availableBytes))
                                .font(.system(size: 36, weight: .semibold, design: .rounded)).tracking(-1.2).monospacedDigit()
                            Text("free").font(.title3).foregroundStyle(.secondary)
                        }
                        Text("\(ByteText.compact(volume.usedBytes)) used of \(ByteText.compact(volume.totalBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Checking disk space…").font(.title3)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 10) {
                    Button(model.isScanning ? "Cancel Scan" : "Scan Now") {
                        model.isScanning ? model.cancelScan() : model.startScan()
                    }.disabled(!model.isScanning && (model.isBusy || model.isReviewingDeletion))
                    Button("Clean Build Output…") { model.requestQuickCleanup() }
                        .buttonStyle(.borderedProminent).tint(DiskSiftTheme.node)
                        .disabled(model.snapshot.artifacts.isEmpty || model.isBusy || model.isReviewingDeletion)
                    if model.isSnapshotStale && model.snapshot.finishedAt != .distantPast {
                        Label("Scan needed", systemImage: "clock").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if let volume = model.volume {
                GeometryReader { geometry in
                    Capsule().fill(.primary.opacity(0.06))
                    Capsule().fill(DiskSiftTheme.node.gradient)
                        .frame(width: geometry.size.width * min(1, max(0, volume.usedFraction)))
                }.frame(height: 6)
                    .accessibilityLabel("\(Int(volume.usedFraction * 100)) percent used")
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16).fill(.background.secondary)
                RoundedRectangle(cornerRadius: 16).fill(LinearGradient(colors: [DiskSiftTheme.node.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
    }

    private var typeBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By type").font(.callout.weight(.semibold))
            ForEach(Array(model.snapshot.content.summaries.prefix(6))) { summary in
                Button { openFiles(summary.kind) } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: summary.kind.icon).foregroundStyle(summary.kind.color).frame(width: 18)
                            Text(summary.kind.title).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(ByteText.compact(summary.allocatedBytes)).monospacedDigit()
                        }.font(.callout)
                        GeometryReader { proxy in
                            Capsule().fill(summary.kind.color.opacity(0.09))
                            Capsule().fill(summary.kind.color.gradient)
                                .frame(width: max(2, proxy.size.width * Double(summary.allocatedBytes) / Double(max(1, model.snapshot.content.allocatedBytes))))
                        }.frame(height: 4)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if model.snapshot.content.summaries.count > 6 {
                Button("All \(model.snapshot.content.summaries.count) types") { openFiles(nil) }
                    .buttonStyle(.link).font(.caption)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var largestFiles: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Largest files").font(.callout.weight(.semibold))
            ForEach(largest) { item in
                Button {
                    if let openFile { openFile(item) } else { openFiles(item.kind) }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            Text(item.url.deletingLastPathComponent().path.abbreviatingHome)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Text(ByteText.compact(item.allocatedBytes)).font(.caption.weight(.medium)).monospacedDigit()
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help(item.path)
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func recoveryCard(_ title: String, subtitle: String, bytes: Int64, icon: String, color: Color,
                              available: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(title, systemImage: icon).font(.callout.weight(.semibold)).foregroundStyle(color)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(color)
                }
                Text(available ? ByteText.compact(bytes) : "—")
                    .font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(0.12), lineWidth: 0.5))
        }.buttonStyle(.plain)
    }
}
