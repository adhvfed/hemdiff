import XCTest
@testable import DiskSift

@MainActor
final class FileReviewModelTests: XCTestCase {
    func testReviewSortingUpdatesCheckedAndCachedItems() async {
        var builder = ContentInventoryBuilder()
        let a = ContentItem(path: "/test/a.log", kind: .logs, allocatedBytes: 10, modifiedAt: nil, isPackage: false)
        let b = ContentItem(path: "/test/b.log", kind: .logs, allocatedBytes: 20, modifiedAt: Date(), isPackage: false)
        builder.record(a); builder.record(b)
        let review = FileReviewModel(protectionCheck: { Dictionary(uniqueKeysWithValues: $0.map { ($0.path, .untracked) }) })
        await review.load(builder.inventory)
        review.toggle(a); review.toggle(b)
        XCTAssertEqual(review.checkedItems.map(\.path), [b.path, a.path])
        review.order = .name
        await review.load(builder.inventory)
        XCTAssertEqual(review.items.map(\.path), [a.path, b.path])
        XCTAssertEqual(review.checkedItems.map(\.path), [a.path, b.path])
        review.order = .modified
        XCTAssertEqual(review.checkedItems.map(\.path), [b.path, a.path])
    }

    func testCheckedItemsSurviveCategoryChangesAndPaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSiftReview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try ContentIndex(path: root.appendingPathComponent("files.sqlite").path, create: true)
        for number in 0..<600 {
            try index.append(ContentItem(path: "/root/\(number).txt", kind: number % 2 == 0 ? .documents : .logs, allocatedBytes: Int64(number), modifiedAt: nil, isPackage: false))
        }
        try index.finish()
        let inventory = try index.inventory()
        let review = FileReviewModel(protectionCheck: { Dictionary(uniqueKeysWithValues: $0.map { ($0.path, .untracked) }) })
        await review.load(inventory)
        let first = try XCTUnwrap(review.items.first)
        review.focused = [first.path]
        review.toggleFocused()
        await review.load(inventory, offset: 250)
        XCTAssertEqual(review.checked.count, 1)
        review.kinds = [.documents]
        await review.load(inventory)
        XCTAssertTrue(review.items.allSatisfy { $0.kind == .documents })
        XCTAssertEqual(review.checkedBytes, first.allocatedBytes)
        review.toggle(try XCTUnwrap(review.items.first))
        XCTAssertEqual(review.checked.count, 2)
        review.removeChecked([first.path])
        XCTAssertEqual(review.checked.count, 1)
        review.clear()
        XCTAssertTrue(review.checked.isEmpty)
    }
}

extension FileReviewModelTests {
    func testLastPageDeletionClampsOffsetAndRefreshesSelection() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("review-page-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let index = try ContentIndex(path: path, create: true)
        for n in 0..<251 {
            try index.append(ContentItem(path: "/fixture/\(n)", kind: .other, allocatedBytes: Int64(n), modifiedAt: nil, isPackage: false))
        }
        try index.finish()
        let review = FileReviewModel(protectionCheck: { Dictionary(uniqueKeysWithValues: $0.map { ($0.path, .untracked) }) })
        await review.load(try index.inventory(), offset: 250)
        let removed = try XCTUnwrap(review.items.first)
        try index.remove(paths: [removed.path])
        await review.load(try index.inventory(), offset: 250)
        XCTAssertEqual(review.offset, 0)
        XCTAssertEqual(review.count, 250)
        XCTAssertFalse(review.items.isEmpty)
        XCTAssertFalse(review.focused.contains(removed.path))
    }

    func testTrackedAndUnknownItemsCannotBeChecked() async {
        var builder = ContentInventoryBuilder()
        for name in ["tracked", "unknown", "untracked"] {
            builder.record(ContentItem(path: "/fixture/\(name)", kind: .documents, allocatedBytes: 10, modifiedAt: nil, isPackage: false))
        }
        let review = FileReviewModel(protectionCheck: { items in
            Dictionary(uniqueKeysWithValues: items.map { ($0.path, FileGitStatus(rawValue: $0.url.lastPathComponent)!) })
        })
        await review.load(builder.inventory)
        review.checkPage()
        XCTAssertEqual(Set(review.checked.keys), ["/fixture/untracked"])
        review.toggle(review.items.first { $0.path.hasSuffix("/tracked") }!)
        XCTAssertEqual(review.checked.count, 1)
    }
}

extension FileReviewModelTests {
    func testCancellationDuringProtectionCheckClearsBusyState() async throws {
        var builder = ContentInventoryBuilder()
        builder.record(ContentItem(path: "/fixture/file", kind: .other, allocatedBytes: 1, modifiedAt: nil, isPackage: false))
        let started = expectation(description: "Protection check started")
        let review = FileReviewModel(protectionCheck: { _ in
            started.fulfill()
            try? await Task.sleep(for: .seconds(30))
            return [:]
        })
        let task = Task { await review.load(builder.inventory) }
        await fulfillment(of: [started], timeout: 10)
        task.cancel()
        await task.value
        XCTAssertFalse(review.isLoading)
        XCTAssertFalse(review.isVerifyingProtection)
        XCTAssertNil(review.error)
    }

    func testReplacementScanDiscardsSelectionsFromPreviousIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HemdiffReview-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let review = FileReviewModel(protectionCheck: { items in
            Dictionary(uniqueKeysWithValues: items.map { ($0.path, .untracked) })
        })
        for scan in 0..<2 {
            let index = try ContentIndex(path: directory.appendingPathComponent("\(scan).sqlite").path, create: true)
            try index.append(ContentItem(path: "/fixture/\(scan)", kind: .other, allocatedBytes: 1, modifiedAt: nil, isPackage: false))
            try index.finish()
            await review.load(try index.inventory())
            XCTAssertTrue(review.checked.isEmpty)
            review.checkPage()
            XCTAssertEqual(review.checked.count, 1)
        }
        XCTAssertEqual(Set(review.checked.keys), ["/fixture/1"])
        XCTAssertEqual(Set(review.protection.keys), ["/fixture/1"])
    }
    func testNewQueryCancelsPreviousProtectionInspection() async throws {
        var builder = ContentInventoryBuilder()
        for name in ["first", "second"] {
            builder.record(ContentItem(path: "/fixture/\(name)", kind: .other, allocatedBytes: 1, modifiedAt: nil, isPackage: false))
        }
        let started = expectation(description: "First inspection started")
        let cancelled = expectation(description: "Obsolete inspection cancelled")
        let review = FileReviewModel(protectionCheck: { items in
            if items.first?.path == "/fixture/first" {
                started.fulfill()
                do { try await Task.sleep(for: .seconds(30)) }
                catch is CancellationError { cancelled.fulfill() }
                catch {}
            }
            return Dictionary(uniqueKeysWithValues: items.map { ($0.path, .untracked) })
        })
        review.search = "first"
        let previous = Task { await review.load(builder.inventory) }
        await fulfillment(of: [started], timeout: 10)
        review.search = "second"
        await review.load(builder.inventory)
        await fulfillment(of: [cancelled], timeout: 10)
        await previous.value
        XCTAssertEqual(review.items.map(\.path), ["/fixture/second"])
        XCTAssertFalse(review.isVerifyingProtection)
    }

}
