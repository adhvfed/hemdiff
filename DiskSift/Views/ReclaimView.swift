import SwiftUI

struct ReclaimView: View {
    @EnvironmentObject private var model: AppModel
    @State private var family = "All tools"
    @State private var search = ""
    @State private var confirmsReclaim = false
    @State private var pending: [Artifact] = []
    @State private var groupByProject = true

    private var visible: [Artifact] {
        model.snapshot.artifacts.filter {
            (family == "All tools" || $0.kind.family == family)
                && (search.isEmpty || $0.path.localizedStandardContains(search))
        }.sorted { $0.allocatedBytes > $1.allocatedBytes }
    }
    private var groups: [(name: String, artifacts: [Artifact], bytes: Int64)] {
        Dictionary(grouping: visible, by: { groupByProject ? $0.projectPath : $0.kind.title })
            .map { key, items in (name: key, artifacts: items, bytes: items.reduce(0) { $0 + $1.allocatedBytes }) }
            .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Build output").font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-0.6)
                Spacer()
                Toggle("Group by project", isOn: $groupByProject).toggleStyle(.switch).controlSize(.small)
            }
            SpaceHero(title: "Rebuildable storage", bytes: model.snapshot.artifactBytes,
                      subtitle: "\(model.snapshot.artifacts.count) folders across \(Set(model.snapshot.artifacts.map(\.projectPath)).count) projects",
                      fraction: Double(model.snapshot.artifactBytes) / Double(max(1, model.volume?.usedBytes ?? model.snapshot.artifactBytes)))
            ModelMessages()
            HStack {
                TextField("Filter by project or path", text: $search).textFieldStyle(.roundedBorder)
                Picker("Tool", selection: $family) {
                    Text("All tools").tag("All tools")
                    ForEach(Array(Set(model.snapshot.artifacts.map { $0.kind.family })).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(width: 180)
                Button("Check Visible") { model.select(visible) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.name) { group in
                        VStack(spacing: 0) {
                            HStack {
                                Button {
                                    let ids = Set(group.artifacts.map(\.id))
                                    if ids.isSubset(of: model.selectedArtifactIDs) { model.selectedArtifactIDs.subtract(ids) }
                                    else { model.selectedArtifactIDs.formUnion(ids) }
                                } label: {
                                    Image(systemName: Set(group.artifacts.map(\.id)).isSubset(of: model.selectedArtifactIDs) ? "checkmark.square.fill" : "square")
                                }.buttonStyle(.plain).foregroundStyle(DiskSiftTheme.node).accessibilityLabel("Check group \(group.name)")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(groupByProject ? URL(fileURLWithPath: group.name).lastPathComponent : group.name).font(.headline)
                                    if groupByProject { Text(group.name.abbreviatingHome).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                }
                                Spacer()
                                Text(ByteText.string(group.bytes)).font(.title3.weight(.semibold)).monospacedDigit()
                            }.padding(16).background(DiskSiftTheme.node.opacity(0.05))
                            ForEach(group.artifacts) { artifact in
                                VStack(alignment: .leading, spacing: 0) {
                                    ArtifactRow(artifact: artifact, selectable: true)
                                    Text(artifact.kind.consequence).font(.caption).foregroundStyle(.secondary).padding(.leading, 56).padding(.bottom, 12)
                                }.padding(.horizontal, 16)
                            }
                        }.background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
                    }
                    if visible.isEmpty { ContentUnavailableView("No matching build folders", systemImage: "shippingbox") }
                }
            }
        }.padding(28)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(DiskSiftTheme.node)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.selectedArtifacts.count) checked · \(ByteText.string(model.selectedBytes))").font(.callout.weight(.semibold)).monospacedDigit()
                    Text("Stop running builds and dev servers before cleanup.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { model.deselectAll() }.disabled(model.selectedArtifactIDs.isEmpty)
                Button("Delete Build Output…") { pending = model.selectedArtifacts; confirmsReclaim = true }
                    .buttonStyle(.borderedProminent).tint(DiskSiftTheme.node)
                    .disabled(model.selectedArtifactIDs.isEmpty || model.isBusy)
            }.padding(.horizontal, 28).padding(.vertical, 18).background(.bar).overlay(alignment: .top) { Divider() }
        }
        .navigationTitle("Cleanup")
        .sheet(isPresented: $confirmsReclaim) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Delete build output?").font(.title2.weight(.semibold))
                Text("\(pending.count) folders · \(ByteText.string(pending.reduce(0) { $0 + $1.allocatedBytes }))").font(.title3)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(pending) { artifact in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(artifact.path.abbreviatingHome).font(.callout.weight(.medium))
                                Text(artifact.kind.consequence).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxHeight: 240)
                Text("Deletion skips Trash and cannot be undone.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { confirmsReclaim = false }.keyboardShortcut(.cancelAction)
                    Button("Delete Permanently", role: .destructive) {
                        let reviewed = pending
                        confirmsReclaim = false
                        Task { await model.reclaimReviewed(reviewed) }
                    }.buttonStyle(.borderedProminent).tint(DiskSiftTheme.rust).disabled(model.isBusy)
                }
            }.padding(24).frame(width: 560)
                .onAppear { model.isReviewingDeletion = true }
                .onDisappear { model.isReviewingDeletion = false }
        }
    }
}
