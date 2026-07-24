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

    private let scanner: ArtifactScanner
    private let volumeMonitor: VolumeMonitor
    private let snapshotStore: SnapshotStore
    private let reclaimer: ArtifactReclaimer
    private var scanTask: Task<Void, Never>?
    private var volumeTask: Task<Void, Never>?

    static let freshnessInterval: TimeInterval = 6 * 60 * 60
    private static let rootsDefaultsKey = "scanRootPaths"

    init(
        scanner: ArtifactScanner = ArtifactScanner(),
        volumeMonitor: VolumeMonitor = VolumeMonitor(),
        snapshotStore: SnapshotStore = SnapshotStore(),
        reclaimer: ArtifactReclaimer = ArtifactReclaimer()
    ) {
        self.scanner = scanner
        self.volumeMonitor = volumeMonitor
        self.snapshotStore = snapshotStore
        self.reclaimer = reclaimer
        snapshot = (try? snapshotStore.load()) ?? .empty

        let savedPaths = UserDefaults.standard.stringArray(forKey: Self.rootsDefaultsKey)
        if let savedPaths {
            scanRoots = savedPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else {
            scanRoots = []
        }

        refreshVolume()
        volumeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                self?.refreshVolume()
            }
        }

        Task { [weak self] in
            guard let self else { return }
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
        !snapshot.isFresh(maxAge: Self.freshnessInterval)
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
        guard !isScanning else { return }
        isScanning = true
        scanProgress = ScanProgress(
            currentPath: "Using the macOS project index",
            entriesVisited: 0,
            artifactsFound: 0,
            bytesMeasured: 0
        )
        errorMessage = nil
        noticeMessage = nil

        let configuration = ScanConfiguration(
            automaticDiscoveryRoot: FileManager.default.homeDirectoryForCurrentUser,
            explicitRoots: scanRoots
        )
        let scanner = scanner
        let store = snapshotStore
        let progressRelay = ScanProgressRelay(model: self)
        scanTask = Task { [weak self] in
            do {
                let completed = try await scanner.scan(configuration: configuration) { progress in
                    progressRelay.send(progress)
                }
                guard let self, !Task.isCancelled else { return }
                self.snapshot = completed
                self.selectedArtifactIDs.formIntersection(Set(completed.artifacts.map(\.id)))
                self.isScanning = false
                self.scanProgress = nil
                self.refreshVolume()
                do {
                    try store.save(completed)
                } catch {
                    self.errorMessage = "The scan finished, but its cache could not be saved."
                }
            } catch is CancellationError {
                self?.isScanning = false
                self?.scanProgress = nil
            } catch {
                self?.isScanning = false
                self?.scanProgress = nil
                self?.errorMessage = "Scan stopped: \(error.localizedDescription)"
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
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

    func reclaimSelected() async {
        let artifacts = selectedArtifacts
        await reclaim(artifacts)
    }

    func reclaim(_ artifact: Artifact) async {
        guard let currentArtifact = snapshot.artifacts.first(where: { $0.id == artifact.id }) else {
            errorMessage = "That folder is no longer in the current inventory. Scan again before cleaning it."
            return
        }
        await reclaim([currentArtifact])
    }

    private func reclaim(_ artifacts: [Artifact]) async {
        guard !artifacts.isEmpty else { return }
        let artifactIDs = Set(artifacts.map(\.id))
        guard reclaimingArtifactIDs.isDisjoint(with: artifactIDs) else {
            errorMessage = "Cleanup is already in progress for one of those folders."
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
            noticeMessage = "Permanently deleted \(result.reclaimedIDs.count) folder\(result.reclaimedIDs.count == 1 ? "" : "s") and reclaimed \(ByteText.compact(result.reclaimedBytes))."
        }

        if !result.failures.isEmpty {
            let details = result.failures.values.prefix(2).joined(separator: " ")
            errorMessage = "\(result.failures.count) folder\(result.failures.count == 1 ? "" : "s") could not be deleted. \(details)"
        }
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

    fileprivate func receiveScanProgress(_ progress: ScanProgress) {
        scanProgress = progress
    }

    private func persistRoots() {
        UserDefaults.standard.set(scanRoots.map(\.path), forKey: Self.rootsDefaultsKey)
    }
}

private final class ScanProgressRelay: @unchecked Sendable {
    weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func send(_ progress: ScanProgress) {
        DispatchQueue.main.async { [weak self] in
            self?.model?.receiveScanProgress(progress)
        }
    }
}
