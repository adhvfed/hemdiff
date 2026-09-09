import Foundation
import XCTest
@testable import DiskSift

final class ContentClassificationTests: XCTestCase {
    func testClassifiesFormatsWithoutTreatingAmbiguousBinariesAsModels() {
        let cases: [(String, ContentKind)] = [
            ("clip.MKV", .video), ("mix.flac", .audio), ("photo.HEIC", .images),
            ("notes.pdf", .documents), ("backup.tar.gz", .archives), ("setup.dmg", .diskImages),
            ("disk.qcow2", .virtualMachines), ("weights.safetensors", .models),
            ("model.GGUF", .models), ("rows.parquet", .databases), ("index.sqlite", .databases),
            ("main.rs", .sourceCode), ("Dockerfile", .sourceCode), (".env", .sourceCode),
            ("mystery.bin", .other), ("unknown", .other)
        ]
        for (name, expected) in cases {
            XCTAssertEqual(ContentKind.classify(URL(fileURLWithPath: name)), expected, name)
        }
        XCTAssertEqual(ContentKind.classify(URL(fileURLWithPath: "Guest.utm"), isDirectory: true), .virtualMachines)
        XCTAssertEqual(ContentKind.classify(URL(fileURLWithPath: "Photos.photoslibrary"), isDirectory: true), .images)
        XCTAssertEqual(ContentKind.classify(URL(fileURLWithPath: "Tool.app"), isDirectory: true), .applications)
        XCTAssertEqual(ContentKind.classify(URL(fileURLWithPath: "backup.sparsebundle"), isDirectory: true), .diskImages)
    }

    func testRetainsLargestItemsButTotalsIncludeEveryFile() throws {
        var builder = ContentInventoryBuilder()
        for size in 1...250 {
            builder.record(ContentItem(path: "/file-\(size)", kind: .video, allocatedBytes: Int64(size), modifiedAt: nil, isPackage: false))
        }
        let summary = try XCTUnwrap(builder.inventory.summaries.first)
        XCTAssertEqual(summary.count, 250)
        XCTAssertEqual(summary.allocatedBytes, 31_375)
        XCTAssertEqual(summary.largestItems.count, ContentInventory.itemLimitPerKind)
        XCTAssertEqual(summary.largestItems.first?.allocatedBytes, 250)
        XCTAssertEqual(summary.largestItems.last?.allocatedBytes, 151)
    }

    func testExplicitScanClassifiesFilesAndExcludesBuildAndGitContents() async throws {
        let fixture = try ContentFixture()
        defer { fixture.remove() }
        try fixture.file("media/movie.mp4", size: 8_192)
        try fixture.file("notes.txt", size: 4_096)
        try fixture.file("project/package.json", size: 4_096)
        try fixture.file("project/node_modules/dependency/movie.mp4", size: 16_384)
        try fixture.file("project/.git/objects/blob", size: 4_096)
        try FileManager.default.createSymbolicLink(at: fixture.url.appendingPathComponent("linked.mp4"), withDestinationURL: fixture.url.appendingPathComponent("media/movie.mp4"))
        let snapshot = try await ArtifactScanner().scan(roots: [fixture.url, fixture.url.appendingPathComponent("media"), fixture.url])
        XCTAssertEqual(snapshot.content.count, 3)
        XCTAssertEqual(snapshot.content.errorsSkipped, 0)
        XCTAssertEqual(Set(snapshot.content.summaries.map(\.kind)), [.video, .documents, .sourceCode])
        let video = try XCTUnwrap(snapshot.content.summaries.first { $0.kind == .video })
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(video.allocatedBytes, 8_192)
        XCTAssertEqual(snapshot.artifacts.count, 1)
    }

    func testAutomaticDiscoveryDoesNotWalkPersonalContent() async throws {
        let fixture = try ContentFixture()
        defer { fixture.remove() }
        try fixture.file("Downloads/movie.mp4", size: 4_096)
        let scanner = ArtifactScanner(locator: ProjectLocator(indexedPaths: { _ in [] }))
        let automatic = try await scanner.scan(configuration: ScanConfiguration(automaticDiscoveryRoot: fixture.url, explicitRoots: []))
        XCTAssertEqual(automatic.content.count, 0)
        let explicit = try await scanner.scan(roots: [fixture.url.appendingPathComponent("Downloads")])
        XCTAssertEqual(explicit.content.count, 1)
    }

    func testPackagesAreMeasuredOnceIncludingWhenSelectedAsRoot() async throws {
        let fixture = try ContentFixture()
        defer { fixture.remove() }
        try fixture.file("Guest.utm/Data/disk.qcow2", size: 8_192)
        try fixture.file("Guest.utm/config.plist", size: 4_096)
        let package = fixture.url.appendingPathComponent("Guest.utm")
        let parentScan = try await ArtifactScanner().scan(roots: [fixture.url])
        let rootScan = try await ArtifactScanner().scan(roots: [package])
        for inventory in [parentScan.content, rootScan.content] {
            XCTAssertEqual(inventory.count, 1)
            let item = try XCTUnwrap(inventory.summaries.first?.largestItems.first)
            XCTAssertEqual(item.kind, .virtualMachines)
            XCTAssertEqual(item.allocatedBytes, 12_288)
            XCTAssertTrue(item.isPackage)
        }
    }

    func testSymlinkRootIsRejectedAndReported() async throws {
        let fixture = try ContentFixture()
        defer { fixture.remove() }
        try fixture.file("real/photo.jpg", size: 4_096)
        let alias = fixture.url.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.url.appendingPathComponent("real"))
        let scan = try await ArtifactScanner().scan(roots: [alias])
        XCTAssertEqual(scan.content.count, 0)
        XCTAssertEqual(scan.content.errorsSkipped, 1)
    }

    func testClassificationProgressIsThrottledAcrossRoots() async throws {
        let fixture = try ContentFixture()
        defer { fixture.remove() }
        let recorder = ProgressRecorder()
        let roots = (0..<3).map { fixture.url.appendingPathComponent("root-\($0)") }
        for index in 0..<768 { try fixture.file("root-\(index / 256)/file-\(index).txt", size: 32) }
        let snapshot = try await ArtifactScanner().scan(roots: roots) { recorder.record($0) }
        let events = recorder.events
        XCTAssertEqual(snapshot.content.count, 768)
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.contains { $0.1.filesClassified > 0 })
        for (before, after) in zip(events, events.dropFirst()) {
            XCTAssertGreaterThanOrEqual(after.0 - before.0, 0.24)
        }
    }

    func testOldCacheIsDiscardedBeforeDecodingNewFields() throws {
        let fixture = try ContentFixture()
        defer { fixture.remove() }
        let file = fixture.url.appendingPathComponent("snapshot.json")
        try Data(#"{"schemaVersion":8}"#.utf8).write(to: file)
        XCTAssertNil(try SnapshotStore(fileURL: file).load())
    }

    func testContentCacheRoundTripAndCleanupPreservesPersonalFiles() throws {
        let fixture = try ContentFixture()
        defer { fixture.remove() }
        var snapshot = DiskSnapshot.empty
        var builder = ContentInventoryBuilder()
        builder.record(ContentItem(path: "/photo.jpg", kind: .images, allocatedBytes: 8_192, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), isPackage: false))
        snapshot.content = builder.inventory
        let store = SnapshotStore(fileURL: fixture.url.appendingPathComponent("snapshot.json"))
        try store.save(snapshot)
        XCTAssertEqual(try store.load(), snapshot)
        XCTAssertEqual(snapshot.removingArtifacts(withIDs: []).content, snapshot.content)
    }
}

private struct ContentFixture {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSiftContent-\(UUID().uuidString)")
    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    func file(_ path: String, size: Int) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: size).write(to: file)
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(TimeInterval, ScanProgress)] = []
    func record(_ progress: ScanProgress) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append((ProcessInfo.processInfo.systemUptime, progress))
    }
    var events: [(TimeInterval, ScanProgress)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
