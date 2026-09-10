import Foundation
import XCTest
@testable import DiskSift

final class FileOperationsTests: XCTestCase {
    func testFullIndexPagesFiltersAndRemovesBeyondLargestHundred() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try ContentIndex(path: root.appendingPathComponent("files.sqlite").path, create: true)
        for number in 0..<360 {
            try index.append(ContentItem(path: "/test/file-\(number).txt", kind: number % 2 == 0 ? .documents : .logs, allocatedBytes: Int64(number), modifiedAt: nil, isPackage: false))
        }
        try index.finish()
        XCTAssertEqual(try index.page(kinds: [], search: "", order: .size, offset: 0).count, 360)
        XCTAssertEqual(try index.page(kinds: [], search: "", order: .size, offset: 250).items.count, 110)
        XCTAssertEqual(try index.page(kinds: [.logs], search: "file-35", order: .name, offset: 0).count, 6)
        try index.remove(paths: ["/test/file-359.txt"])
        XCTAssertEqual(try index.inventory().count, 359)
        XCTAssertEqual(try index.page(kinds: [], search: "", order: .size, offset: 0).items.first?.allocatedBytes, 358)
    }

    func testTrashMoveRejectsChangedFileAndNeverFallsBackToDeletion() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeItem(root.appendingPathComponent("first.log"))
        let changed = try makeItem(root.appendingPathComponent("changed.log"))
        try Data("changed".utf8).write(to: changed.url)
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let operations = FileOperations(trashItem: { url in try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent)) })
        let result = await operations.moveToTrash([first, changed], allowedRoots: [root])
        XCTAssertEqual(result.succeeded.map(\.path), [first.path])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: changed.path))
        let remaining = try makeItem(root.appendingPathComponent("remaining.txt"))
        let denied = FileOperations(trashItem: { _ in throw CocoaError(.fileWriteNoPermission) })
        let failure = await denied.moveToTrash([remaining], allowedRoots: [root])
        XCTAssertEqual(failure.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: remaining.path))
    }

    func testEmptyTrashOnlyDeletesReviewedChildrenAndPreservesNewArrivals() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeItem(root.appendingPathComponent("reviewed.txt"))
        let operations = FileOperations()
        let snapshot = await operations.measureTrash(roots: [root])
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertGreaterThan(snapshot.bytes, 0)
        let added = try makeItem(root.appendingPathComponent("new.txt"))
        let result = await operations.deleteFromTrash(snapshot.items, roots: [root])
        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: added.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testTrashDeletionRejectsOutsidePathAndReplacement() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let outside = try makeItem(root.appendingPathComponent("outside.txt"))
        let replaced = try makeItem(trash.appendingPathComponent("replaced.txt"))
        try FileManager.default.removeItem(at: replaced.url)
        _ = try makeItem(replaced.url)
        let result = await FileOperations().deleteFromTrash([outside, replaced], roots: [trash])
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertTrue(result.succeeded.isEmpty)
    }

    func testFileSymlinkCannotBeTrashedAsOriginalFile() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try makeItem(root.appendingPathComponent("original"))
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file.url)
        let item = ContentItem(path: link.path, kind: .other, allocatedBytes: 0, modifiedAt: nil, isPackage: false, stamp: try FileStamp.capture(link))
        XCTAssertThrowsError(try FileOperations().validate(item))
    }

    func testTrashMoveRechecksGitAfterBrowsingAndKeepsTrackedSource() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeItem(root.appendingPathComponent("source.log"))
        let output = try makeItem(root.appendingPathComponent("output.log"))
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try git(["init", "-q"])
        let hint = await FileGitProtection().statuses(for: [source, output])
        XCTAssertEqual(hint[source.path], .untracked)
        try git(["add", "source.log"])
        let destination = root.appendingPathComponent("moved.log")
        let result = await FileOperations(trashItem: { url in
            try FileManager.default.moveItem(at: url, to: destination)
        }).moveToTrash([source, output], allowedRoots: [root])
        XCTAssertEqual(result.succeeded.map(\.path), [output.path])
        XCTAssertNotNil(result.failures[source.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSiftFileOps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func makeItem(_ url: URL) throws -> ContentItem {
        try Data(repeating: 42, count: 4096).write(to: url)
        return ContentItem(path: url.standardizedFileURL.path, kind: .documents, allocatedBytes: 4096, modifiedAt: nil, isPackage: false, stamp: try FileStamp.capture(url))
    }
}
