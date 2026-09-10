import Foundation
import SQLite3
import XCTest
@testable import DiskSift

final class ContentIndexUpdateTests: XCTestCase {
    func testRemovalUpdatesAllDescendantsWithoutMatchingSimilarNames() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("index-test-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let index = try ContentIndex(path: path, create: true)
        for name in ["/root/a%_", "/root/a%_/nested/file", "/root/a%_other", "/root/aX_"] {
            try index.append(ContentItem(path: name, kind: .other, allocatedBytes: 10, modifiedAt: nil, isPackage: false))
        }
        try index.finish()
        try index.remove(paths: ["/root/a%_"])
        let inventory = try index.inventory()
        XCTAssertEqual(inventory.count, 2)
        XCTAssertEqual(inventory.allocatedBytes, 20)
        XCTAssertEqual(Set(inventory.summaries.flatMap(\.largestItems).map(\.path)), ["/root/a%_other", "/root/aX_"])
    }

    func testReclassificationUsesIndexWithoutReadingMissingFilesAndRunsOnlyOnce() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("index-test-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let index = try ContentIndex(path: path, create: true)
        try index.append(ContentItem(path: "/not-present/libtorch.dylib", kind: .other, allocatedBytes: 4096, modifiedAt: nil, isPackage: false))
        try index.finish()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version=0", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertTrue(try index.reclassifyIfNeeded())
        XCTAssertFalse(try index.reclassifyIfNeeded())
        let inventory = try index.inventory()
        XCTAssertEqual(inventory.summaries.first?.kind, .binaries)
        XCTAssertEqual(inventory.allocatedBytes, 4096)
        XCTAssertEqual(inventory.summaries.first?.largestItems.first?.kind, .binaries)
    }

    func testLegacySnapshotRemovalKeepsUnrelatedItems() {
        var builder = ContentInventoryBuilder()
        builder.record(ContentItem(path: "/root/log", kind: .logs, allocatedBytes: 20, modifiedAt: nil, isPackage: false))
        builder.record(ContentItem(path: "/root/photo", kind: .images, allocatedBytes: 10, modifiedAt: nil, isPackage: false))
        let updated = builder.inventory.removing(paths: ["/root/log"])
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated.allocatedBytes, 10)
        XCTAssertEqual(updated.summaries.first?.kind, .images)
    }
}
