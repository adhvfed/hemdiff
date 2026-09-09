import XCTest
@testable import DiskSift

@MainActor
final class FileReviewModelTests: XCTestCase {
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
