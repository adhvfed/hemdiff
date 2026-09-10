import Foundation
import XCTest

@testable import HemdiffAgentKit
@testable import HemdiffCore

final class InventoryPagesTests: XCTestCase {
  func testDiagnosticsArePaginatedAndReachable() async throws {
    let pages = InventoryPages()
    let errors = (0..<503).map { "Skipped path \($0)" }
    var page = try await pages.store(
      ArtifactInventory(
        hostID: "host", candidates: [], directoriesVisited: 503, errors: errors, cancelled: false),
      limit: 100)
    var collected = page.errors
    XCTAssertEqual(page.totalErrors, 503)
    XCTAssertEqual(page.errors.count, 100)
    while let cursor = page.nextCursor {
      page = try await pages.page(cursor: cursor, limit: 100)
      XCTAssertLessThanOrEqual(page.errors.count, 100)
      collected += page.errors
    }
    XCTAssertEqual(collected, errors)
  }
}
