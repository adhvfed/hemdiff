import Foundation
import XCTest

@testable import HemdiffCore

private struct IdleInteractiveActivity: ArtifactActivityChecking {
  func assess(project: URL, artifact: URL) throws -> ActivityAssessment {
    .init(state: .noDetectedActivity, detail: "Fixture")
  }
}

private struct BusyInteractiveActivity: ArtifactActivityChecking {
  func assess(project: URL, artifact: URL) throws -> ActivityAssessment {
    .init(state: .busy, detail: "A process has build output open")
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
  func testExplicitOverrideDeletesBusyRecentOutputAndChangesAfterReview() throws {
    let (home, artifact) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let service = InteractiveCleanup(
      activity: BusyInteractiveActivity(),
      coordinationDirectory: home.appendingPathComponent("coordination"))
    XCTAssertThrowsError(try service.prepare([artifact]))
    let plan = try service.prepare([artifact], allowingActiveOutput: true)
    XCTAssertTrue(plan.allowsActiveOutput)
    try Data("new build output".utf8).write(to: artifact.url.appendingPathComponent("output"))
    try Data("another file".utf8).write(to: artifact.url.appendingPathComponent("new-output"))
    let result = service.execute(plan)
    XCTAssertEqual(result.reclaimedIDs, [artifact.id])
    XCTAssertTrue(result.failures.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.projectURL.appendingPathComponent("package.json").path))
  }

  func testOverrideRejectsReplacedRoot() throws {
    let (home, artifact) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let service = InteractiveCleanup(activity: BusyInteractiveActivity(),
      coordinationDirectory: home.appendingPathComponent("coordination"))
    let plan = try service.prepare([artifact], allowingActiveOutput: true)
    try FileManager.default.moveItem(at: artifact.url, to: home.appendingPathComponent("original"))
    try FileManager.default.createDirectory(at: artifact.url, withIntermediateDirectories: true)
    try Data("replacement".utf8).write(to: artifact.url.appendingPathComponent("keep"))
    XCTAssertTrue(service.execute(plan).reclaimedIDs.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.appendingPathComponent("keep").path))
  }

  func testOverrideDoesNotFollowSymlinkAndRejectsNestedVersionControl() throws {
    let (home, artifact) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let outside = home.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: outside.appendingPathComponent("keep"))
    try FileManager.default.createSymbolicLink(at: artifact.url.appendingPathComponent("link"), withDestinationURL: outside)
    let service = InteractiveCleanup(activity: BusyInteractiveActivity(),
      coordinationDirectory: home.appendingPathComponent("coordination"))
    let plan = try service.prepare([artifact], allowingActiveOutput: true)
    try FileManager.default.createDirectory(at: artifact.url.appendingPathComponent(".git"), withIntermediateDirectories: true)
    XCTAssertTrue(service.execute(plan).reclaimedIDs.isEmpty)
    try FileManager.default.removeItem(at: artifact.url.appendingPathComponent(".git"))
    XCTAssertEqual(service.execute(plan).reclaimedIDs, [artifact.id])
    XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("keep"), encoding: .utf8), "keep")
  }

  func testOverrideStillRejectsChangedProjectMarker() throws {
    let (home, artifact) = try fixture()
    defer { try? FileManager.default.removeItem(at: home) }
    let service = InteractiveCleanup(activity: BusyInteractiveActivity(),
      coordinationDirectory: home.appendingPathComponent("coordination"))
    let plan = try service.prepare([artifact], allowingActiveOutput: true)
    try Data("{\"changed\":true}".utf8).write(to: artifact.projectURL.appendingPathComponent("package.json"))
    XCTAssertFalse(service.execute(plan).failures.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
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
