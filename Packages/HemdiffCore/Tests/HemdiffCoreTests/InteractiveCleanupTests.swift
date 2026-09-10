import Foundation
import XCTest

@testable import HemdiffCore

private struct IdleInteractiveActivity: ArtifactActivityChecking {
  func assess(project: URL, artifact: URL) throws -> ActivityAssessment {
    .init(state: .noDetectedActivity, detail: "Fixture")
  }
}

private final class SlowFinalInspection: ArtifactActivityChecking, @unchecked Sendable {
  private var calls = 0
  func assess(project: URL, artifact: URL) throws -> ActivityAssessment {
    calls += 1
    if calls == 3 { Thread.sleep(forTimeInterval: 1.1) }
    return .init(state: .noDetectedActivity, detail: "Fixture")
  }
}

final class InteractiveCleanupTests: XCTestCase {
  private func fixture(xcode: Bool = false) throws -> (URL, Artifact) {
    let home = PathSafety.physicalSystemPath(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let project =
      xcode
      ? ArtifactContainers.xcodeDerivedDataRoot(in: home) : home.appendingPathComponent("project")
    let output = project.appendingPathComponent(xcode ? "Example-abcdef" : ".next")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    if !xcode { try Data("{}".utf8).write(to: project.appendingPathComponent("package.json")) }
    try Data("original".utf8).write(to: output.appendingPathComponent("output"))
    return (
      home,
      Artifact(
        kind: xcode ? .xcodeDerivedData : .nextBuild, path: output.path,
        projectPath: project.path, allocatedBytes: 0, createdAt: nil, modifiedAt: nil,
        fileIdentity: try ArtifactFileIdentity.capture(at: output))
    )
  }
  func testReviewExpiringDuringFinalInspectionPreservesOutput() throws {
    let (home, artifact) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let service = InteractiveCleanup(
      activity: SlowFinalInspection(), quietInterval: 0, lifetime: 1,
      coordinationDirectory: home.appendingPathComponent("coordination"))
    let plan = try service.prepare([artifact])
    let result = service.execute(plan)
    XCTAssertTrue(result.reclaimedIDs.isEmpty)
    XCTAssertFalse(result.failures.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
  }
  func testDescendantChangedAfterReviewPreservesWholeSelection() throws {
    let (home, artifact) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let service = InteractiveCleanup(
      activity: IdleInteractiveActivity(), quietInterval: 0,
      coordinationDirectory: home.appendingPathComponent("coordination"))
    let plan = try service.prepare([artifact])
    try Data("new user content".utf8).write(to: artifact.url.appendingPathComponent("output"))
    let result = service.execute(plan)
    XCTAssertTrue(result.reclaimedIDs.isEmpty)
    XCTAssertFalse(result.failures.isEmpty)
    XCTAssertEqual(
      try String(contentsOf: artifact.url.appendingPathComponent("output"), encoding: .utf8),
      "new user content")
  }
  func testKnownXcodeContainerUsesSameReviewAndRemoval() throws {
    let (home, artifact) = try fixture(xcode: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let service = InteractiveCleanup(
      validator: ArtifactReclaimer(homeDirectory: home), activity: IdleInteractiveActivity(),
      quietInterval: 0, coordinationDirectory: home.appendingPathComponent("coordination"))
    let plan = try service.prepare([artifact])
    XCTAssertGreaterThan(plan.estimatedBytes, 0)
    XCTAssertEqual(service.execute(plan).reclaimedIDs, [artifact.id])
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.projectPath))
  }
  func testContainerBypassIsNotAvailableToHeadlessSnapshot() throws {
    let (home, artifact) = try fixture(xcode: true)
    defer { try? FileManager.default.removeItem(at: home) }
    XCTAssertThrowsError(
      try ArtifactFilesystem.snapshot(artifact, quietInterval: 0, now: Date(), cancelled: { false })
    )
    let service = InteractiveCleanup(
      activity: IdleInteractiveActivity(), quietInterval: 0,
      coordinationDirectory: home.appendingPathComponent("coordination"))
    XCTAssertThrowsError(try service.prepare([artifact]))
  }
  func testCancelledPreparationDoesNotDeleteAndForeignPlanIsRejected() throws {
    let (home, artifact) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let service = InteractiveCleanup(
      activity: IdleInteractiveActivity(), quietInterval: 0,
      coordinationDirectory: home.appendingPathComponent("coordination"))
    XCTAssertThrowsError(try service.prepare([artifact], cancelled: { true }))
    let plan = try service.prepare([artifact])
    let other = InteractiveCleanup(
      activity: IdleInteractiveActivity(), quietInterval: 0,
      coordinationDirectory: home.appendingPathComponent("coordination"))
    XCTAssertTrue(other.execute(plan).reclaimedIDs.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
  }
  func testMarkerChangedDuringConfirmationPreservesOutput() throws {
    let (home, artifact) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let service = InteractiveCleanup(
      activity: IdleInteractiveActivity(), quietInterval: 0,
      coordinationDirectory: home.appendingPathComponent("coordination"))
    let plan = try service.prepare([artifact])
    try Data("{\"changed\":true}".utf8).write(
      to: artifact.projectURL.appendingPathComponent("package.json"))
    XCTAssertFalse(service.execute(plan).failures.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
  }
  func testExpiredReviewCannotDelete() throws {
    let (home, artifact) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let service = InteractiveCleanup(
      activity: IdleInteractiveActivity(), quietInterval: 0, lifetime: 1,
      coordinationDirectory: home.appendingPathComponent("coordination"))
    let plan = try service.prepare([artifact])
    Thread.sleep(forTimeInterval: 1.05)
    XCTAssertFalse(service.execute(plan).failures.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
  }

}
