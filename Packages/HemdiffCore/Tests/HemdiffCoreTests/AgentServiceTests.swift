import Foundation
import XCTest

@testable import HemdiffCore

private struct TestActivity: ArtifactActivityChecking {
  let state: ActivityAssessment.State
  func assess(project: URL, artifact: URL) throws -> ActivityAssessment {
    .init(state: state, detail: "Fixture activity: \(state)")
  }
}
final class AgentServiceTests: XCTestCase {
  private struct Fixture {
    let base: URL, root: URL, project: URL, output: URL, state: URL
    let service: AgentArtifactService
    let rootID: String
    init(
      activity: ActivityAssessment.State = .noDetectedActivity, quiet: TimeInterval = 0,
      lifetime: TimeInterval = 300
    ) throws {
      base = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hemdiff-service-\(UUID().uuidString)")
      root = base.appendingPathComponent("workspace")
      project = root.appendingPathComponent("project")
      output = project.appendingPathComponent(".next")
      state = base.appendingPathComponent("state")
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      try Data("{\"private\":true}".utf8).write(to: project.appendingPathComponent("package.json"))
      try Data(repeating: 42, count: 4096).write(to: output.appendingPathComponent("chunk"))
      try Data("source".utf8).write(to: project.appendingPathComponent("source.ts"))
      service = try AgentArtifactService(
        stateDirectory: state, activityChecker: TestActivity(state: activity), quietInterval: quiet,
        planLifetime: lifetime)
      rootID = try service.configureRoot(root).id
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
    func plan() throws -> CleanupPlan {
      try service.grant(rootID: rootID, kinds: [.nextBuild])
      return try service.prepare(candidateIDs: service.inventory().candidates.map(\.id))
    }
    func execute(_ plan: CleanupPlan) throws -> CleanupReceipt {
      try service.execute(planID: plan.id, expectedHostID: plan.hostID)
    }
  }
  func testReadConfigurationDoesNotAuthorizeDeletion() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let inventory = try f.service.inventory()
    XCTAssertEqual(inventory.candidates.count, 1)
    XCTAssertFalse(inventory.candidates[0].authorized)
    XCTAssertThrowsError(try f.service.prepare(candidateIDs: inventory.candidates.map(\.id)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: f.output.path))
  }
  func testSuccessfulCleanupAndDurableIdempotentReceipt() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let plan = try f.plan()
    let result = try f.execute(plan)
    XCTAssertEqual(result.outcome, .completed)
    XCTAssertTrue(result.accountingComplete)
    XCTAssertGreaterThan(result.estimatedRemovedBytes, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.path))
    XCTAssertEqual(
      try String(contentsOf: f.project.appendingPathComponent("source.ts"), encoding: .utf8),
      "source")
    let fresh = try AgentArtifactService(stateDirectory: f.state)
    XCTAssertEqual(try fresh.execute(planID: plan.id, expectedHostID: plan.hostID), result)
    XCTAssertEqual(try fresh.receipt(planID: plan.id), result)
  }
  func testRevokedPermissionInvalidatesPlan() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let plan = try f.plan()
    try f.service.revoke(rootID: f.rootID)
    XCTAssertThrowsError(try f.execute(plan))
    XCTAssertTrue(FileManager.default.fileExists(atPath: f.output.path))
  }
  func testChildContentReplacementInvalidatesPlan() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let plan = try f.plan()
    try Data(repeating: 43, count: 4096).write(to: f.output.appendingPathComponent("chunk"))
    XCTAssertThrowsError(try f.execute(plan))
  }
  func testDirectoryReplacementInvalidatesPlan() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let plan = try f.plan()
    try FileManager.default.moveItem(at: f.output, to: f.project.appendingPathComponent("old"))
    try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: true)
    XCTAssertThrowsError(try f.execute(plan))
  }
  func testChangedMarkerInvalidatesPlan() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let plan = try f.plan()
    try Data("{\"changed\":true}".utf8).write(to: f.project.appendingPathComponent("package.json"))
    XCTAssertThrowsError(try f.execute(plan))
  }
  func testWrongHostAndMalformedIDRefused() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let plan = try f.plan()
    XCTAssertThrowsError(try f.service.execute(planID: plan.id, expectedHostID: UUID().uuidString))
    XCTAssertThrowsError(
      try f.service.execute(planID: "../configuration", expectedHostID: plan.hostID))
  }
  func testExpiredPlanRefused() throws {
    let f = try Fixture(lifetime: 0.001)
    defer { f.cleanup() }
    let plan = try f.plan()
    Thread.sleep(forTimeInterval: 0.02)
    XCTAssertThrowsError(try f.execute(plan))
  }
  func testBusyUnknownAndRecentOutputsRefused() throws {
    for status in [ActivityAssessment.State.busy, .unknown] {
      let f = try Fixture(activity: status)
      defer { f.cleanup() }
      XCTAssertThrowsError(try f.plan())
    }
    let f = try Fixture(quiet: 30)
    defer { f.cleanup() }
    XCTAssertThrowsError(try f.plan())
  }
  func testDescendantLinkIsUnlinkedWithoutTouchingTarget() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let outside = f.base.appendingPathComponent("outside")
    try Data("precious".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: f.output.appendingPathComponent("link"), withDestinationURL: outside)
    let plan = try f.plan()
    XCTAssertEqual(try f.execute(plan).outcome, .completed)
    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "precious")
  }
  func testReplacedLinkIsRefused() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let link = f.output.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/first")
    let plan = try f.plan()
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/second")
    XCTAssertThrowsError(try f.execute(plan))
  }
  func testRootAndAncestorLinksRefused() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let link = f.base.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.root)
    XCTAssertThrowsError(try f.service.configureRoot(link))
    XCTAssertThrowsError(try f.service.configureRoot(link.appendingPathComponent("project")))
  }
  func testNestedVersionControlRefused() throws {
    for name in [".git", ".hg", ".svn"] {
      let f = try Fixture()
      defer { f.cleanup() }
      try Data("metadata".utf8).write(to: f.output.appendingPathComponent(name))
      let result = try f.service.inventory()
      XCTAssertTrue(result.candidates.isEmpty)
      XCTAssertFalse(result.errors.isEmpty)
    }
  }
  func testGitTrackedOutputRefused() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    XCTAssertEqual(try HostCommand.run(["/usr/bin/git", "-C", f.project.path, "init", "-q"]).0, 0)
    XCTAssertEqual(
      try HostCommand.run(["/usr/bin/git", "-C", f.project.path, "add", ".next/chunk"]).0, 0)
    XCTAssertThrowsError(try f.plan())
  }
  func testStateModesAndLinksAreRefused() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let bad = f.base.appendingPathComponent("bad")
    try FileManager.default.createDirectory(
      at: bad, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    XCTAssertThrowsError(try AgentArtifactService(stateDirectory: bad))
    let link = f.base.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.state)
    XCTAssertThrowsError(try AgentArtifactService(stateDirectory: link))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644],
      ofItemAtPath: f.state.appendingPathComponent("configuration.json").path)
    XCTAssertThrowsError(try f.service.status())
  }
  func testInterruptedJournalNeverDeletesOnRetry() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let plan = try f.plan()
    let state = try AgentState(url: f.state)
    try state.write(["planID": plan.id], to: plan.id + ".started.json")
    let result = try f.execute(plan)
    XCTAssertEqual(result.outcome, .interrupted)
    XCTAssertFalse(result.accountingComplete)
    XCTAssertTrue(FileManager.default.fileExists(atPath: f.output.path))
    XCTAssertEqual(try f.execute(plan), result)
  }
  func testConcurrentOperationRefused() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let state = try AgentState(url: f.state)
    try state.locked { XCTAssertThrowsError(try f.service.status()) }
  }
  func testCancelledInventoryAndPlanningDoNotMutate() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    XCTAssertTrue(try f.service.inventory(cancelled: { true }).cancelled)
    let ids = try f.service.inventory().candidates.map(\.id)
    try f.service.grant(rootID: f.rootID, kinds: [.nextBuild])
    XCTAssertThrowsError(try f.service.prepare(candidateIDs: ids, cancelled: { true }))
    XCTAssertTrue(FileManager.default.fileExists(atPath: f.output.path))
  }
  func testCommandDeadlineAfterOutputClosesAndCancellation() throws {
    let start = Date()
    XCTAssertThrowsError(try HostCommand.run(["/bin/sh", "-c", "exec 1>&-; sleep 10"], timeout: 1))
    XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    XCTAssertThrowsError(try HostCommand.run(["/bin/sh", "-c", "sleep 10"], cancelled: { true }))
  }
  func testKnownIdleBuildProcessWithProjectCWDIsBusy() throws {
    #if os(macOS) || os(Linux)
      let f = try Fixture()
      defer { f.cleanup() }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
      process.arguments = ["-c", "import time; time.sleep(10)"]
      process.currentDirectoryURL = f.project
      try process.run()
      defer {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
      }
      Thread.sleep(forTimeInterval: 0.1)
      let assessment = try HostArtifactActivityChecker().assess(
        project: f.project, artifact: f.output)
      XCTAssertEqual(assessment.state, .busy, assessment.detail)
    #endif
  }
  func testInternalAndExternalHardlinksRemainSafe() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let original = f.output.appendingPathComponent("chunk")
    let sibling = f.output.appendingPathComponent("second")
    let external = f.base.appendingPathComponent("external")
    try FileManager.default.linkItem(at: original, to: sibling)
    try FileManager.default.linkItem(at: original, to: external)
    let plan = try f.plan()
    XCTAssertEqual(try f.execute(plan).outcome, .completed)
    XCTAssertEqual(try Data(contentsOf: external), Data(repeating: 42, count: 4096))
  }
  func testPublicPlanExcludesPrivateManifestAndMarkerContents() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let plan = try f.plan()
    let encoded = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
    XCTAssertFalse(encoded.contains("snapshots"))
    XCTAssertFalse(encoded.contains("markerDigests"))
    let stored = try String(
      contentsOf: f.state.appendingPathComponent(plan.id + ".plan.json"), encoding: .utf8)
    XCTAssertTrue(stored.contains("markerDigests"))
    XCTAssertFalse(stored.contains("private\\\":true"))
  }
  func testMigratedStateRefused() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let state = try AgentState(url: f.state)
    let config = try state.configuration()
    let changed = AgentConfiguration(
      version: 1, hostID: config.hostID, machineBinding: "other-machine", roots: config.roots)
    try state.write(changed, to: "configuration.json")
    XCTAssertThrowsError(try f.service.status())
    XCTAssertThrowsError(try AgentArtifactService(stateDirectory: f.state))
  }
  func testCancellationAfterJournalProducesDurablePartialReceipt() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let plan = try f.plan()
    let result = try f.service.execute(
      planID: plan.id, expectedHostID: plan.hostID,
      cancelled: {
        FileManager.default.fileExists(
          atPath: f.state.appendingPathComponent(plan.id + ".started.json").path)
      })
    XCTAssertEqual(result.outcome, .partial)
    XCTAssertFalse(result.accountingComplete)
    XCTAssertTrue(FileManager.default.fileExists(atPath: f.output.path))
    XCTAssertEqual(try f.execute(plan), result)
  }
  func testSpecialFileRefusedWithoutBlocking() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let fifo = f.output.appendingPathComponent("fifo")
    XCTAssertEqual(try HostCommand.run(["/usr/bin/mkfifo", fifo.path]).0, 0)
    let inventory = try f.service.inventory()
    XCTAssertTrue(inventory.candidates.isEmpty)
    XCTAssertFalse(inventory.errors.isEmpty)
  }
  func testNewEntryDuringDeletionIsPreserved() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    try Data("second".utf8).write(to: f.output.appendingPathComponent("z-last"))
    let candidate = try XCTUnwrap(f.service.inventory().candidates.first)
    let snapshot = try ArtifactFilesystem.snapshot(
      candidate.artifact, quietInterval: 0, now: Date(), cancelled: { false })
    var steps = 0
    let added = f.output.appendingPathComponent("new-source")
    XCTAssertThrowsError(
      try ArtifactFilesystem.remove(
        candidate.artifact, stamp: snapshot,
        cancelled: {
          steps += 1
          if steps == 3 { try? Data("keep".utf8).write(to: added) }
          return false
        }))
    XCTAssertEqual(try String(contentsOf: added, encoding: .utf8), "keep")
  }
  func testBothSiblingArtifactsCanBeCleanedInOnePlan() throws {
    let f = try Fixture()
    defer { f.cleanup() }
    let modules = f.project.appendingPathComponent("node_modules")
    try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
    try Data("dependency".utf8).write(to: modules.appendingPathComponent("module.js"))
    try f.service.grant(rootID: f.rootID, kinds: [.nextBuild, .nodeModules])
    let plan = try f.service.prepare(candidateIDs: f.service.inventory().candidates.map(\.id))
    XCTAssertEqual(try f.execute(plan).outcome, .completed)
  }

}
