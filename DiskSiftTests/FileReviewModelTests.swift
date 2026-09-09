import XCTest
@testable import DiskSift

@MainActor
final class FileReviewModelTests: XCTestCase {
    func testReviewSortingUpdatesCheckedAndCachedItems() async {
        var builder = ContentInventoryBuilder()
        let a = ContentItem(path: "/test/a.log", kind: .logs, allocatedBytes: 10, modifiedAt: nil, isPackage: false)
        let b = ContentItem(path: "/test/b.log", kind: .logs, allocatedBytes: 20, modifiedAt: Date(), isPackage: false)
        builder.record(a); builder.record(b)
        let review = FileReviewModel()
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
        let review = FileReviewModel()
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
