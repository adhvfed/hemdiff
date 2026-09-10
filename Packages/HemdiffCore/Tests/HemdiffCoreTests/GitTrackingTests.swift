import Foundation
import XCTest

@testable import HemdiffCore

final class GitTrackingTests: XCTestCase {
  func testBatchProtectsTrackedFilesAndPackageDescendantsWithoutTreatingWildcardsAsPatterns() throws
  {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try git(root, ["init", "-q"])
    let tracked = try file(root, "source.swift")
    let staged = try file(root, "staged.log")
    let packageFile = try file(root, "Example.app/Contents/source")
    let wildcard = try file(root, "[source].swift")
    let free = try file(root, "output.log")
    try git(root, ["add", "--", "source.swift", "staged.log", "Example.app"])
    let package = packageFile.deletingLastPathComponent().deletingLastPathComponent()
    let statuses = GitTracking.statuses(for: [tracked, staged, package, wildcard, free])
    XCTAssertEqual(statuses[tracked.path], .tracked)
    XCTAssertEqual(statuses[staged.path], .tracked)
    XCTAssertEqual(statuses[package.path], .tracked)
    XCTAssertEqual(statuses[wildcard.path], .untracked)
    XCTAssertEqual(statuses[free.path], .untracked)
    #if os(macOS)
      let renamed = root.appendingPathComponent("SOURCE.swift")
      try FileManager.default.moveItem(at: tracked, to: renamed)
      XCTAssertEqual(GitTracking.statuses(for: [renamed])[renamed.path], .tracked)
    #endif
    try git(root, ["add", "output.log"])
    XCTAssertEqual(
      GitTracking.statuses(for: [free])[free.path], .tracked,
      "A previous untracked result must not authorize later removal")
  }

  func testWorktreeGitFileAndBrokenRepositoryFailClosed() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = root.appendingPathComponent("main")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try git(repository, ["init", "-q"])
    _ = try file(repository, "source")
    try git(repository, ["add", "."])
    try git(
      repository,
      [
        "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm",
        "fixture",
      ])
    let worktree = root.appendingPathComponent("worktree")
    try git(repository, ["worktree", "add", "--detach", worktree.path])
    let tracked = worktree.appendingPathComponent("source")
    XCTAssertEqual(GitTracking.statuses(for: [tracked])[tracked.path], .tracked)
    try Data("gitdir: /does-not-exist-hemdiff\n".utf8).write(
      to: worktree.appendingPathComponent(".git"))
    XCTAssertEqual(GitTracking.statuses(for: [tracked])[tracked.path], .unknown)
  }

  func testOutsideRepositoriesAndNestedRepositoryContainers() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let free = try file(root, "plain.log")
    XCTAssertEqual(GitTracking.statuses(for: [free])[free.path], .untracked)
    let package = root.appendingPathComponent("Nested.app")
    let nested = package.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try git(nested, ["init", "-q"])
    XCTAssertEqual(GitTracking.statuses(for: [package])[package.path], .tracked)
    XCTAssertEqual(GitTracking.statuses(for: [free], cancelled: { true })[free.path], .unknown)
  }

  func testVisiblePageBatchPerformanceAndShallowPackageHints() throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try git(root, ["init", "-q"])
    var files: [URL] = []
    for number in 0..<1_000 { files.append(try file(root, "file-\(number).log")) }
    try git(root, ["add", "."])
    let selected = Array(files.prefix(250))
    let start = Date()
    let statuses = GitTracking.statuses(for: selected, inspectContainers: false)
    print(
      "Git protection: 250 selected / 1,000 tracked in \(Date().timeIntervalSince(start)) seconds")
    XCTAssertEqual(statuses.count, 250)
    XCTAssertTrue(statuses.values.allSatisfy { $0 == .tracked })
    let package = root.appendingPathComponent("Untracked.app")
    _ = try file(package, "Contents/file")
    XCTAssertEqual(
      GitTracking.statuses(for: [package], inspectContainers: false)[package.path], .unknown)
    XCTAssertEqual(GitTracking.statuses(for: [package])[package.path], .untracked)
    let metadata = root.appendingPathComponent(".git/index")
    XCTAssertEqual(GitTracking.statuses(for: [metadata])[metadata.path], .tracked)
  }

  private func fixture() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "HemdiffGit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private func file(_ root: URL, _ path: String) throws -> URL {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: url)
    return url
  }
  private func git(_ root: URL, _ arguments: [String]) throws {
    let result = try HostCommand.run(["/usr/bin/git", "-C", root.path] + arguments)
    XCTAssertEqual(result.0, 0, String(decoding: result.1, as: UTF8.self))
  }
}
