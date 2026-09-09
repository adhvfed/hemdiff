import AppKit
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

    func testQuickCleanupOpensFixedReviewWithoutDeletingAndBlocksScan() throws {
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
        model.isShowingSetup = true
        model.requestQuickCleanup()
        XCTAssertNil(model.pendingQuickCleanup)
        model.isShowingSetup = false
        model.requestQuickCleanup()
        XCTAssertEqual(model.destination, .reclaim)
        XCTAssertEqual(model.pendingQuickCleanup, snapshot.artifacts)
        XCTAssertTrue(model.isReviewingDeletion)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        model.deselectAll()
        XCTAssertEqual(model.pendingQuickCleanup, snapshot.artifacts)
        model.startScan()
        XCTAssertFalse(model.isScanning)
    }

    func testQuickCleanupDoesNothingWithoutArtifacts() throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        model.requestQuickCleanup()
        XCTAssertNil(model.pendingQuickCleanup)
        XCTAssertFalse(model.isReviewingDeletion)
        XCTAssertEqual(model.destination, .overview)
    }

    func testMenuBarIconHasStatusItemSizeAndTemplateRendering() {
        let image = MenuBarIcon.image
        XCTAssertEqual(image.size.width, 22)
        XCTAssertEqual(image.size.height, 22)
        XCTAssertTrue(image.isTemplate)
        XCTAssertNotNil(image.tiffRepresentation)
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

extension AppModelTests {
    func testNativeStatusItemCanBeCreatedHiddenAndRestored() throws {
        let suite = "HemdiffStatusTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let controller = MenuBarController(defaults: defaults, autosaveName: suite)
        defer {
            controller.removeStatusItem()
            defaults.removePersistentDomain(forName: suite)
        }
        controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let initial = try XCTUnwrap(controller.statusItem)
        XCTAssertTrue(initial.isVisible)
        XCTAssertNotNil(initial.button?.window)
        XCTAssertGreaterThan(initial.button?.bounds.width ?? 0, 0)
        XCTAssertEqual(initial.button?.image?.size.width, 22)
        initial.isVisible = false
        controller.updateVisibility()
        XCTAssertTrue(initial.isVisible)
        defaults.set(false, forKey: "showsMenuBarExtra")
        controller.updateVisibility()
        XCTAssertNil(controller.statusItem)
        defaults.set(true, forKey: "showsMenuBarExtra")
        controller.updateVisibility()
        XCTAssertTrue(try XCTUnwrap(controller.statusItem).isVisible)
        XCTAssertFalse(controller.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}

extension AppModelTests {
    func testSetupSavesReviewedRootsAndStartsFirstScan() async throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let root = fixture.url.appendingPathComponent("Work")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = fixture.model()
        model.isShowingSetup = true
        model.completeSetup(scanRoots: [root, root.appendingPathComponent("child")])
        XCTAssertEqual(model.scanRoots.map(\.path), [root.path])
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "scanRootPaths"), [root.path])
        XCTAssertTrue(fixture.defaults.bool(forKey: "setupCompleted"))
        XCTAssertFalse(model.isShowingSetup)
        XCTAssertTrue(model.isScanning)
        try await waitForScan(model)
        XCTAssertNotEqual(model.snapshot.finishedAt, .distantPast)
    }

    func testSetupLaterDoesNotImmediatelyStartScanOrChangeRoots() throws {
        let fixture = try ModelFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        let roots = model.scanRoots
        model.isShowingSetup = true
        model.finishSetup(startScan: false)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.scanRoots, roots)
        XCTAssertFalse(model.isShowingSetup)
    }
}
