import Foundation
import XCTest

@testable import HemdiffCore

final class CleanupExecutionLockTests: XCTestCase {
  func testLeaseIsExclusiveAndReleasedAfterFailure() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hemdiff-lease-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    enum FixtureError: Error { case intentional }
    XCTAssertThrowsError(
      try CleanupExecutionLock.withLock(at: directory) {
        XCTAssertThrowsError(try CleanupExecutionLock.withLock(at: directory) {})
        throw FixtureError.intentional
      })
    XCTAssertNoThrow(try CleanupExecutionLock.withLock(at: directory) {})
  }
  func testLeaseRejectsLinkedDirectory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hemdiff-lease-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    XCTAssertThrowsError(try CleanupExecutionLock.withLock(at: link) {})
  }
}
