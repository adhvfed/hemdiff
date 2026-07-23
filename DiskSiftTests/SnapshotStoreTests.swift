import Foundation
import XCTest
@testable import DiskSift

final class SnapshotStoreTests: XCTestCase {
    func testCacheRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSiftCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SnapshotStore(fileURL: directory.appendingPathComponent("snapshot.json"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let artifact = Artifact(
            kind: .rustTarget,
            path: "/tmp/App/target",
            projectPath: "/tmp/App",
            allocatedBytes: 42_000,
            createdAt: date,
            modifiedAt: date
        )
        let expected = DiskSnapshot(
            schemaVersion: DiskSnapshot.currentSchemaVersion,
            roots: ["/tmp"],
            startedAt: date,
            finishedAt: date,
            filesVisited: 2,
            directoriesVisited: 3,
            errorsSkipped: 0,
            categories: [
                ScannedCategory(id: "/tmp/App", name: "App", path: "/tmp/App", allocatedBytes: 42_000),
            ],
            artifacts: [artifact]
        )

        try store.save(expected)
        XCTAssertEqual(try store.load(), expected)
    }

    func testRemovingArtifactsUpdatesKnownTotal() {
        let first = Artifact(
            kind: .rustTarget,
            path: "/tmp/One/target",
            projectPath: "/tmp/One",
            allocatedBytes: 10,
            createdAt: nil,
            modifiedAt: nil
        )
        let second = Artifact(
            kind: .nodeModules,
            path: "/tmp/Two/node_modules",
            projectPath: "/tmp/Two",
            allocatedBytes: 20,
            createdAt: nil,
            modifiedAt: nil
        )
        var snapshot = DiskSnapshot.empty
        snapshot.artifacts = [first, second]

        let result = snapshot.removingArtifacts(withIDs: [first.id])
        XCTAssertEqual(result.artifacts, [second])
        XCTAssertEqual(result.artifactBytes, 20)
    }

    func testFreshnessRejectsEmptyFutureAndExpiredSnapshots() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(DiskSnapshot.empty.isFresh(at: now, maxAge: 100))

        var recent = DiskSnapshot.empty
        recent = DiskSnapshot(
            schemaVersion: recent.schemaVersion,
            roots: [],
            startedAt: now.addingTimeInterval(-50),
            finishedAt: now.addingTimeInterval(-20),
            filesVisited: 0,
            directoriesVisited: 0,
            errorsSkipped: 0,
            categories: [],
            artifacts: []
        )
        XCTAssertTrue(recent.isFresh(at: now, maxAge: 100))

        let expired = DiskSnapshot(
            schemaVersion: recent.schemaVersion,
            roots: [],
            startedAt: now.addingTimeInterval(-500),
            finishedAt: now.addingTimeInterval(-200),
            filesVisited: 0,
            directoriesVisited: 0,
            errorsSkipped: 0,
            categories: [],
            artifacts: []
        )
        XCTAssertFalse(expired.isFresh(at: now, maxAge: 100))

        let future = DiskSnapshot(
            schemaVersion: recent.schemaVersion,
            roots: [],
            startedAt: now,
            finishedAt: now.addingTimeInterval(10),
            filesVisited: 0,
            directoriesVisited: 0,
            errorsSkipped: 0,
            categories: [],
            artifacts: []
        )
        XCTAssertFalse(future.isFresh(at: now, maxAge: 100))
    }

    func testCorruptCacheThrowsInsteadOfReturningInvalidData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSiftCacheTests-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("snapshot.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: file)

        XCTAssertThrowsError(try SnapshotStore(fileURL: file).load())
    }
}
