import SwiftUI

struct ReclaimView: View {
    @EnvironmentObject private var model: AppModel
    @State private var family = "All tools"
    @State private var search = ""
    @State private var confirmsReclaim = false
    @State private var pending: [Artifact] = []
    @State private var reviewPlan: InteractiveCleanupPlan?
    @State private var preparationError: String?
    @State private var groupByProject = true
    @State private var collapsed = Set<String>()

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
                if !model.snapshot.artifacts.isEmpty {
                Picker("Group by", selection: $groupByProject) {
                    Text("Project").tag(true)
                    Text("Tool").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 160)
                }
            }
            if !model.snapshot.artifacts.isEmpty {
            SpaceHero(title: "Rebuildable storage", bytes: model.snapshot.artifactBytes,
                      subtitle: "\(model.snapshot.artifacts.count) folders across \(Set(model.snapshot.artifacts.map(\.projectPath)).count) projects")
            }
            ModelMessages()
            if !model.snapshot.artifacts.isEmpty {
            HStack {
                ReviewSearchField(placeholder: "Search project or path", text: $search)
                Picker("Tool", selection: $family) {
                    Text("All tools").tag("All tools")
                    ForEach(Array(Set(model.snapshot.artifacts.map { $0.kind.family })).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(width: 180)
                Button("Check Visible") { model.select(visible) }.disabled(visible.isEmpty)
            }
            }
            if model.snapshot.artifacts.isEmpty {
                VStack(spacing: 0) {
                ReviewEmptyState(title: model.isScanning ? "Looking for build output…" : "No build output to clean", detail: "Scan again after building, or review large files in Files.", icon: "checkmark.seal", fillsSpace: false)
                HStack {
                    Button("Review Large Files") { model.destination = .files }
                    Button("Scan Now") { model.startScan() }.disabled(model.isBusy)
                }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(groups, id: \.name) { group in
                        VStack(spacing: 0) {
                            HStack {
                                Button {
                                    if collapsed.contains(group.name) { collapsed.remove(group.name) }
                                    else { collapsed.insert(group.name) }
                                } label: {
                                    Image(systemName: collapsed.contains(group.name) ? "chevron.right" : "chevron.down")
                                        .font(.caption.weight(.semibold)).frame(width: 12)
                                }.buttonStyle(.plain).help(collapsed.contains(group.name) ? "Expand group" : "Collapse group")
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
                            if !collapsed.contains(group.name) {
                            ForEach(group.artifacts) { artifact in
                                VStack(alignment: .leading, spacing: 0) {
                                    ArtifactRow(artifact: artifact, selectable: true)
                                    Text(artifact.kind.consequence).font(.caption).foregroundStyle(.secondary).padding(.leading, 56).padding(.bottom, 12)
                                }.padding(.horizontal, 16)
                            }
                            }
                        }.background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.4), lineWidth: 0.5))
                    }
                    if visible.isEmpty { ReviewEmptyState(title: "No matching build folders", detail: "Try another search or choose All tools.", icon: "magnifyingglass") }
                }
            }
            }
        }.padding(24)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.snapshot.artifacts.isEmpty {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill").font(.title2).foregroundStyle(DiskSiftTheme.node)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(model.selectedArtifacts.count) checked · \(ByteText.string(model.selectedBytes))").font(.callout.weight(.semibold)).monospacedDigit()
                    Text("Stop running builds and dev servers before cleanup.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { model.deselectAll() }.disabled(model.selectedArtifactIDs.isEmpty)
                Button("Delete Build Output…") { model.requestCleanup(model.selectedArtifacts) }
                    .buttonStyle(HemdiffButtonStyle(emphasis: .primary)).tint(DiskSiftTheme.node)
                    .disabled(model.selectedArtifactIDs.isEmpty || model.isBusy)
            }.padding(.horizontal, 28).padding(.vertical, 18).background(.bar).overlay(alignment: .top) { Divider() }
            }
        }
        .navigationTitle("Cleanup")
        .onChange(of: model.pendingQuickCleanup, initial: true) { _, requested in
            guard let requested else { return }
            reviewPlan = nil
            preparationError = nil
            pending = requested
            model.pendingQuickCleanup = nil
            confirmsReclaim = true
        }
        .sheet(isPresented: $confirmsReclaim) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Delete build output?").font(.title2.weight(.semibold))
                Text("\(pending.count) \(pending.count == 1 ? "folder" : "folders") · \(ByteText.string(reviewPlan?.estimatedBytes ?? pending.reduce(0) { $0 + $1.allocatedBytes })) estimated").font(.title3)
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
                if model.isPreparingCleanup {
                    HStack { ProgressView().controlSize(.small); Text("Checking folders before cleanup…") }
                }
                if let preparationError { Text(preparationError).foregroundStyle(.red).textSelection(.enabled) }
                Text("Stop running builds and dev servers before cleanup. Deletion skips Trash and cannot be undone.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { confirmsReclaim = false }.keyboardShortcut(.cancelAction)
                    Button("Delete Permanently", role: .destructive) {
                        guard let reviewed = reviewPlan else { return }
                        confirmsReclaim = false
                        Task { await model.reclaimReviewed(reviewed) }
                    }.buttonStyle(HemdiffButtonStyle(emphasis: .destructive)).disabled(model.isBusy || reviewPlan == nil)
                }
            }.padding(24).frame(width: 560).buttonStyle(HemdiffButtonStyle())
                .task {
                    do {
                        let plan = try await model.prepareCleanup(pending)
                        try Task.checkCancellation()
                        reviewPlan = plan
                    } catch is CancellationError {} catch {
                        preparationError = error.localizedDescription
                    }
                }
                .onAppear { model.isReviewingDeletion = true }
                .onDisappear {
                    model.isReviewingDeletion = false
                    reviewPlan = nil
                    pending = []
                }
        }
    }
}
