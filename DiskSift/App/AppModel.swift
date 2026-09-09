import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: DiskSnapshot
    @Published private(set) var volume: VolumeSnapshot?
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: ScanProgress?
    @Published var selectedArtifactIDs = Set<Artifact.ID>()
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published private(set) var scanRoots: [URL]
    @Published private(set) var reclaimingArtifactIDs = Set<Artifact.ID>()

    @Published private(set) var trashSnapshot = TrashSnapshot()
    @Published private(set) var isLoadingTrash = false
    @Published private(set) var isManagingFiles = false
    @Published private(set) var contentRevision = 0
    var isReviewingDeletion = false
    private let fileOperations: FileOperations
    var isBusy: Bool { isScanning || isManagingFiles || isLoadingTrash || !reclaimingArtifactIDs.isEmpty }

    private let scanner: ArtifactScanner
    private let volumeMonitor: VolumeMonitor
    private let snapshotStore: SnapshotStore
    private let reclaimer: ArtifactReclaimer
    private let homeDirectory: URL
    private let defaults: UserDefaults
    private var scanTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?
    private var scanGeneration = UUID()

    static let freshnessInterval: TimeInterval = 6 * 60 * 60
    private static let rootsDefaultsKey = "scanRootPaths"

    init(
        scanner: ArtifactScanner = ArtifactScanner(),
        volumeMonitor: VolumeMonitor = VolumeMonitor(),
        snapshotStore: SnapshotStore = SnapshotStore(),
        reclaimer: ArtifactReclaimer = ArtifactReclaimer(),
        fileOperations: FileOperations = FileOperations(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard,
        startsAutomatically: Bool = true
    ) {
        self.scanner = scanner
        self.volumeMonitor = volumeMonitor
        self.snapshotStore = snapshotStore
        self.reclaimer = reclaimer
        self.fileOperations = fileOperations
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.defaults = defaults
        snapshot = (try? snapshotStore.load()) ?? .empty

        let savedPaths = defaults.stringArray(forKey: Self.rootsDefaultsKey)
        if let savedPaths {
            scanRoots = savedPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else {
            let projects = homeDirectory
                .appendingPathComponent("Projects", isDirectory: true)
            var isDirectory: ObjCBool = false
            scanRoots = FileManager.default.fileExists(
                atPath: projects.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue ? [projects] : []
        }

        guard startsAutomatically else { return }
        refreshVolume()
        volumeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                self?.refreshVolume()
                if self?.isSnapshotStale == true {
                    self?.startScan()
                }
            }
        }

        Task { [weak self] in
            guard let self else { return }
            await self.refreshTrash()
            if self.snapshot.finishedAt == .distantPast || self.isSnapshotStale {
                self.startScan()
            }
        }
    }

    deinit {
        scanTask?.cancel()
        volumeTask?.cancel()
    }

    var isSnapshotStale: Bool {
        let expectedRoots = [homeDirectory.path]
            + ArtifactScanner.normalizedRoots(scanRoots).map(\.path)
        return Set(snapshot.roots) != Set(expectedRoots)
            || !snapshot.isFresh(maxAge: Self.freshnessInterval)
    }

    var selectedArtifacts: [Artifact] {
        snapshot.artifacts.filter { selectedArtifactIDs.contains($0.id) }
    }

    var selectedBytes: Int64 {
        selectedArtifacts.reduce(0) { $0 + $1.allocatedBytes }
    }

    func refreshVolume() {
        do {
            volume = try volumeMonitor.measure()
        } catch {
            errorMessage = "Disk capacity could not be refreshed: \(error.localizedDescription)"
        }
    }

    func startScan() {
        guard !isBusy, !isReviewingDeletion else { return }
        scanGeneration = UUID()
        isScanning = true
        scanProgress = ScanProgress(
            currentPath: "Finding projects…",
            entriesVisited: 0,
            artifactsFound: 0,
            bytesMeasured: 0
        )
        errorMessage = nil
        noticeMessage = nil

        let configuration = ScanConfiguration(
            automaticDiscoveryRoot: homeDirectory,
            explicitRoots: scanRoots
        )
        let scanner = scanner
        let store = snapshotStore
        let progressRelay = ScanProgressRelay(model: self, generation: scanGeneration)
        scanTask = Task { [weak self] in
            defer {
                self?.isScanning = false
                self?.scanProgress = nil
            }
            do {
                let completed = try await scanner.scan(configuration: configuration) { progress in
                    progressRelay.send(progress)
                }
                guard let self, !Task.isCancelled else { return }
                let previousIndex = self.snapshot.content.indexPath
                self.snapshot = completed
                self.contentRevision += 1
                self.selectedArtifactIDs.formIntersection(Set(completed.artifacts.map(\.id)))
                self.refreshVolume()
                do {
                    try store.save(completed)
                    if let previousIndex, previousIndex != completed.content.indexPath {
                        Self.removeManagedIndex(previousIndex)
                    }
                } catch {
                    self.errorMessage = "Couldn’t save scan results."
                }
            } catch is CancellationError {
                // Preserve the previous inventory.
            } catch {
                self?.errorMessage = "Scan stopped: \(error.localizedDescription)"
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        // Keep the scan slot occupied until discovery and its subprocess exit.
        scanProgress = nil
    }

    func toggleSelection(_ artifact: Artifact) {
        if selectedArtifactIDs.contains(artifact.id) {
            selectedArtifactIDs.remove(artifact.id)
        } else {
            selectedArtifactIDs.insert(artifact.id)
        }
    }

    func select(_ artifacts: [Artifact]) {
        selectedArtifactIDs.formUnion(artifacts.map(\.id))
    }

    func deselectAll() {
        selectedArtifactIDs.removeAll()
    }

    func reclaimReviewed(_ artifacts: [Artifact]) async {
        // Keep the confirmation's selection fixed even if the visible filter changes.
        let current = Dictionary(uniqueKeysWithValues: snapshot.artifacts.map { ($0.id, $0) })
        await reclaim(artifacts.filter { current[$0.id]?.fileIdentity == $0.fileIdentity })
    }

    func reclaimSelected() async {
        let artifacts = selectedArtifacts
        await reclaim(artifacts)
    }

    func reclaim(_ artifact: Artifact) async {
        guard let currentArtifact = snapshot.artifacts.first(where: { $0.id == artifact.id }),
              currentArtifact.fileIdentity == artifact.fileIdentity else {
            errorMessage = "Folder missing from scan results. Scan again."
            return
        }
        await reclaim([currentArtifact])
    }

    private func reclaim(_ artifacts: [Artifact]) async {
        guard !artifacts.isEmpty else { return }
        guard !isBusy else {
            errorMessage = "Wait for the scan or cleanup to finish."
            return
        }
        let artifactIDs = Set(artifacts.map(\.id))
        guard reclaimingArtifactIDs.isDisjoint(with: artifactIDs) else {
            errorMessage = "Folder deletion is already in progress."
            return
        }

        reclaimingArtifactIDs.formUnion(artifactIDs)
        defer { reclaimingArtifactIDs.subtract(artifactIDs) }
        errorMessage = nil
        noticeMessage = nil

        let result = await reclaimer.reclaim(artifacts)
        if !result.reclaimedIDs.isEmpty {
            snapshot = snapshot.removingArtifacts(withIDs: result.reclaimedIDs)
            selectedArtifactIDs.subtract(result.reclaimedIDs)
            try? snapshotStore.save(snapshot)
            refreshVolume()
            noticeMessage = "Deleted \(result.reclaimedIDs.count) folder\(result.reclaimedIDs.count == 1 ? "" : "s") (\(ByteText.compact(result.reclaimedBytes)))."
        }

        if !result.failures.isEmpty {
            let details = result.failures.values.prefix(2).joined(separator: " ")
            errorMessage = "\(result.failures.count) folder\(result.failures.count == 1 ? "" : "s") could not be deleted. \(details)"
        }
    }

    func refreshTrash() async {
        guard !isLoadingTrash, !isManagingFiles else { return }
        isLoadingTrash = true
        defer { isLoadingTrash = false }
        trashSnapshot = await fileOperations.measureTrash()
    }

    func trashFiles(_ items: [ContentItem]) async -> Set<String> {
        guard !isBusy, !items.isEmpty else { return [] }
        isManagingFiles = true
        defer { isManagingFiles = false }
        errorMessage = nil
        noticeMessage = nil
        let result = await fileOperations.moveToTrash(items, allowedRoots: scanRoots)
        if let path = snapshot.content.indexPath, !result.succeeded.isEmpty {
            do {
                snapshot.content = try await Task.detached(priority: .utility) {
                    let index = try ContentIndex(path: path)
                    try index.remove(paths: result.succeeded.map(\.path))
                    return try index.inventory()
                }.value
                try snapshotStore.save(snapshot)
            } catch { errorMessage = "Files moved, but the inventory couldn’t be updated. Scan again." }
        }
        contentRevision += 1
        if !result.succeeded.isEmpty {
            noticeMessage = "Moved \(result.succeeded.count) items to Trash. Empty Trash to recover space."
        }
        reportFileFailures(result)
        trashSnapshot = await fileOperations.measureTrash()
        refreshVolume()
        return Set(result.succeeded.map(\.path))
    }

    func deleteTrashItems(_ items: [ContentItem]) async -> Set<String> {
        guard !isBusy, !isLoadingTrash, !items.isEmpty else { return [] }
        isManagingFiles = true
        defer { isManagingFiles = false }
        errorMessage = nil
        noticeMessage = nil
        let result = await fileOperations.deleteFromTrash(items, roots: trashSnapshot.roots)
        if !result.succeeded.isEmpty { noticeMessage = "Permanently deleted \(result.succeeded.count) items from Trash." }
        reportFileFailures(result)
        trashSnapshot = await fileOperations.measureTrash()
        refreshVolume()
        return Set(result.succeeded.map(\.path))
    }

    private func reportFileFailures(_ result: FileOperationResult) {
        if !result.failures.isEmpty {
            errorMessage = "\(result.failures.count) items couldn’t be changed. " + result.failures.values.prefix(2).joined(separator: " ")
        }
    }

    private static func removeManagedIndex(_ path: String) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskSift/Indexes").standardizedFileURL
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent() == directory, url.pathExtension == "sqlite" else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func addScanRoot(_ url: URL) {
        let updated = ArtifactScanner.normalizedRoots(scanRoots + [url])
        scanRoots = updated
        persistRoots()
    }

    func removeScanRoot(_ url: URL) {
        scanRoots.removeAll { $0.standardizedFileURL == url.standardizedFileURL }
        persistRoots()
    }

    fileprivate func receiveScanProgress(_ progress: ScanProgress, generation: UUID) {
        guard generation == scanGeneration, isScanning, scanTask?.isCancelled != true else { return }
        scanProgress = progress
    }

    private func persistRoots() {
        defaults.set(scanRoots.map(\.path), forKey: Self.rootsDefaultsKey)
    }
}

private final class ScanProgressRelay: @unchecked Sendable {
    weak var model: AppModel?
    let generation: UUID

    init(model: AppModel, generation: UUID) {
        self.model = model
        self.generation = generation
    }

    func send(_ progress: ScanProgress) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.model?.receiveScanProgress(progress, generation: self.generation)
        }
    }
}
