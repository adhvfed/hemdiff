import Darwin
import Foundation
import XCTest

@testable import HemdiffCore

/// A tree deeper than the walk limit must be refused, not crash the process.
final class DeepTreeTests: XCTestCase {
  private func fixture(depth: Int) throws -> (URL, Artifact) {
    let home = PathSafety.physicalSystemPath(
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let project = home.appendingPathComponent("project")
    let output = project.appendingPathComponent(".next")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
    // One level at a time through the parent descriptor, so the whole path never
    // has to fit in a single PATH_MAX buffer.
    var parent = open(output.path, O_RDONLY | O_DIRECTORY)
    XCTAssertGreaterThanOrEqual(parent, 0)
    for _ in 0..<depth {
      XCTAssertEqual(mkdirat(parent, "d", 0o755), 0)
      let child = openat(parent, "d", O_RDONLY | O_DIRECTORY)
      XCTAssertGreaterThanOrEqual(child, 0)
      close(parent)
      parent = child
    }
    close(parent)
    return (
      home,
      Artifact(
        kind: .nextBuild, path: output.path, projectPath: project.path, allocatedBytes: 0,
        createdAt: nil, modifiedAt: nil,
        fileIdentity: try ArtifactFileIdentity.capture(at: output))
    )
  }

  func testOutputNestedPastTheWalkLimitIsRefused() throws {
    let (home, artifact) = try fixture(depth: ArtifactFilesystem.maximumDepth + 10)
    defer { try? FileManager.default.removeItem(at: home) }
    XCTAssertThrowsError(
      try ArtifactFilesystem.snapshot(
        artifact, quietInterval: 0, now: Date(), cancelled: { false })
    ) { error in
      XCTAssertEqual(
        (error as? AgentServiceError)?.localizedDescription,
        "Build output is nested too deeply to inspect")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
  }

  func testOutputWithinTheWalkLimitIsStillInspected() throws {
    let (home, artifact) = try fixture(depth: 20)
    defer { try? FileManager.default.removeItem(at: home) }
    let stamp = try ArtifactFilesystem.snapshot(
      artifact, quietInterval: 0, now: Date(), cancelled: { false })
    XCTAssertNotNil(stamp.nodes[""])
  }
}
