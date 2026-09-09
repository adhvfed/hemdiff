import Foundation
import XCTest
@testable import DiskSift

@MainActor
final class AppModelTests: XCTestCase {
    func testCancellationRetainsScanSlotUntilWorkerExitsAndAllowsRescan() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.startScan()
        model.cancelScan()
        XCTAssertTrue(model.isScanning)
        model.startScan() // Must not replace the cancelled worker.
        try await waitForScan(model)
        XCTAssertEqual(model.snapshot.finishedAt, .distantPast)
        model.startScan()
        try await waitForScan(model)
        XCTAssertNotEqual(model.snapshot.finishedAt, .distantPast)
        XCTAssertFalse(model.isSnapshotStale)
        model.addScanRoot(fixture.url.appendingPathComponent("new-root"))
        XCTAssertTrue(model.isSnapshotStale)
    }

    func testReclaimCannotDeleteDuringScan() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let target = fixture.url.appendingPathComponent("project/target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("[workspace]".utf8).write(to: target.deletingLastPathComponent().appendingPathComponent("Cargo.toml"))
        var snapshot = DiskSnapshot.empty
        snapshot.artifacts = [Artifact(kind: .rustTarget, path: target.path,
            projectPath: target.deletingLastPathComponent().path, allocatedBytes: 0,
            createdAt: nil, modifiedAt: nil, fileIdentity: try ArtifactFileIdentity.capture(at: target))]
        try fixture.store.save(snapshot)
        let model = fixture.model()
        model.startScan()
        await model.reclaim(snapshot.artifacts[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNotNil(model.errorMessage)
        model.cancelScan()
        try await waitForScan(model)
    }

    private func waitForScan(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.isScanning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isScanning)
    }
}

@MainActor
private final class ModelFixture {
    let url: URL
    let suite = "DiskSiftModelTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: SnapshotStore

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSiftModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
        defaults.set([], forKey: "scanRootPaths")
        store = SnapshotStore(fileURL: url.appendingPathComponent("snapshot.json"))
    }

    func model() -> AppModel {
        AppModel(scanner: ArtifactScanner(locator: ProjectLocator(indexedPaths: { _ in [] })),
                 snapshotStore: store, homeDirectory: url, defaults: defaults, startsAutomatically: false)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: url)
    }
}
