import SwiftUI
import AppKit

enum AppDestination: String, CaseIterable, Identifiable {
    case overview
    case reclaim
    case files
    case trash
    case locations

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Storage"
        case .reclaim: "Cleanup"
        case .files: "Files"
        case .trash: "Trash"
        case .locations: "Scan Locations"
        }
    }

    var icon: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .reclaim: "shippingbox"
        case .files: "doc.on.doc"
        case .trash: "trash"
        case .locations: "folder.badge.gearshape"
        }
    }
}

struct RootView: View {
    @Environment(\.controlActiveState) private var controlState
    @EnvironmentObject private var model: AppModel
    @StateObject private var fileReview = FileReviewModel()

    var body: some View {
        NavigationSplitView {
            List(AppDestination.allCases, selection: $model.destination) { item in
                HStack {
                    Label {
                        Text(item.title).foregroundStyle(model.destination == item && controlState != .inactive ? Color.white : Color.primary)
                    } icon: {
                        Image(systemName: item.icon).foregroundStyle(model.destination == item && controlState != .inactive ? Color.white : DiskSiftTheme.node)
                    }
                    Spacer(minLength: 4)
                    if item == .reclaim && !model.snapshot.artifacts.isEmpty {
                        Text(ByteText.compact(model.snapshot.artifactBytes)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                    .tag(item)
                    .padding(.vertical, 3)
            }
            .safeAreaInset(edge: .top) {
                HStack(spacing: 10) {
                    Image("BrandMark").resizable().scaledToFit().frame(width: 34, height: 34)
                    Text("Hemdiff").font(.system(size: 19, weight: .semibold, design: .rounded)).tracking(-0.5)
                    Spacer()
                }.padding(.horizontal, 18).padding(.vertical, 16)
            }
            .navigationSplitViewColumnWidth(min: 184, ideal: 206)
            .safeAreaInset(edge: .bottom) {
                SidebarStatus()
                    .padding(12)
            }
        } detail: {
            Group {
                switch model.destination ?? .overview {
                case .overview:
                    OverviewView(openReclaim: { model.destination = .reclaim }, openFiles: { kind in
                        fileReview.kinds = kind.map { [$0] } ?? []
                        fileReview.search = ""
                        fileReview.order = .size
                        model.destination = .files
                    }, openTrash: { model.destination = .trash }, openFile: { item in
                        fileReview.kinds = []
                        fileReview.search = item.path
                        fileReview.order = .size
                        model.destination = .files
                    })
                case .reclaim:
                    ReclaimView()
                case .files:
                    FilesView(review: fileReview, openLocations: { model.destination = .locations })
                case .trash:
                    TrashView()
                case .locations:
                    LocationsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
            }
        }
        .onChange(of: model.removedContentPaths) { _, paths in
            let checked = Set(fileReview.checked.keys.filter { file in
                paths.contains { file == $0 || file.hasPrefix($0 + "/") }
            })
            fileReview.removeChecked(checked)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.reconcileKnownRemovals(visiblePaths: fileReview.items.map(\.path)) }
        }
        .sheet(isPresented: $model.isShowingSetup) {
            SetupWizard().environmentObject(model).interactiveDismissDisabled()
        }
        .tint(DiskSiftTheme.node)
        .buttonStyle(HemdiffButtonStyle())
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(model.isScanning ? "Scanning…" : "\(model.scanRoots.count) scan locations")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.destination != .overview {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.isScanning ? model.cancelScan() : model.startScan()
                } label: {
                    Label(
                        model.isScanning ? "Cancel Scan" : "Scan Now",
                        systemImage: model.isScanning ? "stop.fill" : "arrow.clockwise"
                    )
                }
                .help(model.isScanning ? "Cancel the current scan" : "Scan configured locations")
                .disabled(model.isBusy && !model.isScanning)
            }
            }
        }
    }
}

private struct SidebarStatus: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let volume = model.volume {
                HStack {
                    Text(ByteText.compact(volume.availableBytes)).font(.callout.weight(.semibold)).monospacedDigit()
                    Text("free").font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { proxy in
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(DiskSiftTheme.node).frame(width: proxy.size.width * volume.usedFraction)
                }.frame(height: 4).accessibilityLabel("\(Int(volume.usedFraction * 100)) percent used")
            }
            if let progress = model.scanProgress {
                Text(progress.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if model.snapshot.finishedAt != .distantPast {
                Text("Updated \(model.snapshot.finishedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not scanned yet")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
