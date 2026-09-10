import Combine
import Darwin
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: DiskSnapshot
    @Published private(set) var volume: VolumeSnapshot?
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: ScanProgress?
    @Published var destination: AppDestination? = .overview
    @Published var pendingQuickCleanup: [Artifact]?
    @Published var selectedArtifactIDs = Set<Artifact.ID>()
    @Published var errorMessage: String?
    @Published var noticeMessage: String?
    @Published private(set) var scanRoots: [URL]
    @Published private(set) var reclaimingArtifactIDs = Set<Artifact.ID>()

    @Published private(set) var trashSnapshot = TrashSnapshot()
    @Published private(set) var isLoadingTrash = false
    @Published private(set) var isManagingFiles = false
    @Published private(set) var contentRevision = 0
    @Published private(set) var removedContentPaths = Set<String>()
    @Published private(set) var isUpdatingInventory = false
    @Published var isShowingSetup = false
    @Published var setupPage = 0 {
        didSet { defaults.set(setupPage, forKey: "setupPage") }
    }
    func showSetup() {
        defaults.set(true, forKey: "setupInProgress")
        setupPage = 0
        isShowingSetup = true
    }
    func completeSetup(scanRoots: [URL]) {
        self.scanRoots = ArtifactScanner.normalizedRoots(scanRoots)
        persistRoots()
        finishSetup()
    }

    func finishSetup(startScan: Bool = true) {
        defaults.set(true, forKey: "setupCompleted")
        defaults.set(false, forKey: "setupInProgress")
        isShowingSetup = false
        setupPage = 0
        if startScan && isSnapshotStale { self.startScan() }
    }
    @Published var isReviewingDeletion = false
    private let fileOperations: FileOperations
    var isBusy: Bool { isUpdatingInventory || isPreparingCleanup || isScanning || isManagingFiles || isLoadingTrash || !reclaimingArtifactIDs.isEmpty }

    private let scanner: ArtifactScanner
    private let volumeMonitor: VolumeMonitor
    private let snapshotStore: SnapshotStore
    private let cleanup: InteractiveCleanup
    @Published private(set) var isPreparingCleanup = false
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
        self.cleanup = InteractiveCleanup(validator: reclaimer)
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

        setupPage = min(2, max(0, defaults.integer(forKey: "setupPage")))
        isShowingSetup = startsAutomatically && (!defaults.bool(forKey: "setupCompleted") || defaults.bool(forKey: "setupInProgress"))
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
            await self.upgradeClassification()
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
        guard !isBusy, !isReviewingDeletion, !isShowingSetup else { return }
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

    func requestQuickCleanup() {
        guard !isBusy, !isReviewingDeletion, !isShowingSetup, !snapshot.artifacts.isEmpty else { return }
        isReviewingDeletion = true
        destination = .reclaim
        pendingQuickCleanup = snapshot.artifacts.sorted { $0.allocatedBytes > $1.allocatedBytes }
    }

    func requestCleanup(_ artifacts: [Artifact]) {
        guard !isBusy, !isReviewingDeletion else {
            errorMessage = "Wait for the scan or cleanup to finish."
            return
        }
        guard !artifacts.isEmpty else { return }
        isReviewingDeletion = true
        destination = .reclaim
        pendingQuickCleanup = artifacts
    }

    func prepareCleanup(_ artifacts: [Artifact]) async throws -> InteractiveCleanupPlan {
        guard !isBusy else { throw AgentServiceError.refused("Wait for the scan or cleanup to finish.") }
        isPreparingCleanup = true
        defer { isPreparingCleanup = false }
        let service = cleanup
        let worker = Task.detached(priority: .utility) {
            try service.prepare(artifacts, cancelled: { Task.isCancelled })
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    func reclaimReviewed(_ plan: InteractiveCleanupPlan) async {
        guard !isBusy else {
            errorMessage = "Wait for the scan or cleanup to finish."
            return
        }
        let artifactIDs = Set(plan.artifacts.map(\.id))
        reclaimingArtifactIDs.formUnion(artifactIDs)
        defer { reclaimingArtifactIDs.subtract(artifactIDs) }
        errorMessage = nil
        noticeMessage = nil
        let service = cleanup
        let worker = Task.detached(priority: .utility) {
            service.execute(plan, cancelled: { Task.isCancelled })
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
        if !result.reclaimedIDs.isEmpty {
            snapshot = snapshot.removingArtifacts(withIDs: result.reclaimedIDs)
            selectedArtifactIDs.subtract(result.reclaimedIDs)
            await reconcileRemovedPaths(plan.artifacts.filter { result.reclaimedIDs.contains($0.id) }.map(\.path))
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
        if !result.succeeded.isEmpty { await reconcileRemovedPaths(result.succeeded.map(\.path)) }
        if !result.succeeded.isEmpty {
            noticeMessage = "Moved \(result.succeeded.count) items to Trash. Empty Trash to recover space."
        }
        reportFileFailures(result)
        let removed = Set(result.succeeded.map(\.path))
        trashSnapshot.items.removeAll { removed.contains($0.path) }
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
        let removed = Set(result.succeeded.map(\.path))
        trashSnapshot.items.removeAll { removed.contains($0.path) }
        trashSnapshot = await fileOperations.measureTrash()
        refreshVolume()
        return Set(result.succeeded.map(\.path))
    }

    /// Reconcile successful operations by path, never by rerunning discovery.
    private func reconcileRemovedPaths(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        removedContentPaths.formUnion(paths)
        let coverageErrors = snapshot.content.errorsSkipped
        snapshot.content = snapshot.content.removing(paths: paths)
        contentRevision += 1
        if let path = snapshot.content.indexPath {
            do {
                let inventory = try await Task.detached(priority: .utility) {
                    let index = try ContentIndex(path: path)
                    try index.remove(paths: paths)
                    return try index.inventory()
                }.value
                snapshot.content = inventory
                snapshot.content.errorsSkipped = coverageErrors
                contentRevision += 1
            } catch { errorMessage = "Items removed, but the saved file index could not be updated." }
        }
        do { try snapshotStore.save(snapshot) }
        catch { errorMessage = "Items removed, but the updated inventory could not be saved." }
    }

    func upgradeClassification() async {
        guard !isBusy, let path = snapshot.content.indexPath else { return }
        isUpdatingInventory = true
        defer { isUpdatingInventory = false }
        let coverageErrors = snapshot.content.errorsSkipped
        let pendingRemovals = snapshot.content.removedPaths ?? []
        do {
            let inventory = try await Task.detached(priority: .utility) {
                let index = try ContentIndex(path: path)
                if !pendingRemovals.isEmpty { try index.remove(paths: pendingRemovals) }
                _ = try index.reclassifyIfNeeded()
                return try index.inventory()
            }.value
            snapshot.content = inventory
            snapshot.content.errorsSkipped = coverageErrors
            contentRevision += 1
            try snapshotStore.save(snapshot)
        } catch { errorMessage = "Couldn’t update saved file classifications." }
    }

    /// Catch CLI/MCP removals when returning to the app, plus the currently visible file page.
    /// Only ENOENT is disappearance; permission failures never erase inventory entries.
    func reconcileKnownRemovals(visiblePaths: [String] = []) async {
        guard !isBusy, !isReviewingDeletion else { return }
        isUpdatingInventory = true
        defer { isUpdatingInventory = false }
        let paths = Set(snapshot.artifacts.map(\.path) + visiblePaths)
        let missing = await Task.detached(priority: .utility) {
            paths.filter { path in
                var info = stat()
                return lstat(path, &info) != 0 && errno == ENOENT
            }
        }.value
        guard !missing.isEmpty else { refreshVolume(); return }
        let ids = Set(snapshot.artifacts.filter { missing.contains($0.path) }.map(\.id))
        snapshot = snapshot.removingArtifacts(withIDs: ids)
        selectedArtifactIDs.subtract(ids)
        await reconcileRemovedPaths(Array(missing))
        refreshVolume()
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
