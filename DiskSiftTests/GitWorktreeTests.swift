import Foundation
import XCTest
@testable import DiskSift

final class GitWorktreeTests: XCTestCase {
    func testSystemAliasSeedsHaveTheSameRepositoryIdentity() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let main = try XCTUnwrap(GitRepository.at(fixture.main))
        let physical = try XCTUnwrap(GitRepository.at(fixture.main.resolvingSymlinksInPath()))
        XCTAssertEqual(main.commonDirectory.path, physical.commonDirectory.path)
    }

    func testPreferredProjectRootDeprioritizesWorktreePaths() {
        XCTAssertEqual(
            GitRepository.preferredRootPath([
                "/Users/example/worktrees/myproject/feature-x",
                "/Users/example/Projects/myproject"
            ]),
            "/Users/example/Projects/myproject")
    }

    func testRepositorySeedWithoutLinkedWorktreesFindsUnindexedArtifacts() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.artifact(in: fixture.main)
        let locator = ProjectLocator(indexedPaths: { _ in [fixture.main.appendingPathComponent(".git").path] })
        let snapshot = try await ArtifactScanner(locator: locator).scan(configuration: fixture.configuration)
        XCTAssertEqual(snapshot.artifacts.map(\.projectPath), [fixture.main.path])
        XCTAssertNil(snapshot.artifacts.first?.worktreeName)
    }

    func testFindsUnindexedRegisteredWorktreesFromMainRepository() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let linked = try fixture.worktree(".hidden/feature with spaces\nand newline")
        try fixture.artifact(in: linked.appendingPathComponent("packages/app"))
        try fixture.artifact(in: fixture.main)
        // Simulate Spotlight returning only the main repository's Git marker.
        let locator = ProjectLocator(indexedPaths: { _ in [fixture.main.appendingPathComponent(".git").path] })
        let snapshot = try await ArtifactScanner(locator: locator).scan(configuration: fixture.configuration)
        XCTAssertEqual(snapshot.artifacts.count, 2)
        let artifact = try XCTUnwrap(snapshot.artifacts.first { $0.worktreeName != nil })
        XCTAssertEqual(artifact.worktreeName, linked.lastPathComponent)
        XCTAssertEqual(artifact.projectPath, linked.appendingPathComponent("packages/app").path)
        XCTAssertGreaterThan(artifact.allocatedBytes, 0)
        XCTAssertEqual(snapshot.errorsSkipped, 0)
        XCTAssertNoThrow(try ArtifactReclaimer().validate(artifact))
    }

    func testLinkedSeedFindsSiblingAndMainWithoutDuplicates() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let first = try fixture.worktree("trees/one")
        let second = try fixture.worktree("trees/two")
        for root in [fixture.main, first, second] { try fixture.artifact(in: root) }
        let locator = ProjectLocator(indexedPaths: { _ in [first.appendingPathComponent("Cargo.toml").path] })
        let snapshot = try await ArtifactScanner(locator: locator).scan(configuration: fixture.configuration)
        XCTAssertEqual(Set(snapshot.artifacts.map(\.projectPath)), Set([fixture.main.path, first.path, second.path]))
        XCTAssertEqual(snapshot.artifacts.count, 3)
        XCTAssertEqual(Set(snapshot.artifacts.compactMap(\.repositoryCommonPath)).count, 1)
        XCTAssertEqual(Set(snapshot.artifacts.compactMap(\.repositoryRootPath)), Set([fixture.main.path, first.path, second.path]))
        XCTAssertEqual(snapshot.categories.reduce(0) { $0 + $1.allocatedBytes }, snapshot.artifactBytes)
    }

    func testExplicitScanWithoutSpotlightFindsWorktreeRegistry() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let linked = try fixture.worktree(".hidden/feature")
        try fixture.artifact(in: linked)
        let locator = ProjectLocator(indexedPaths: { _ in throw CocoaError(.fileReadUnknown) })
        let snapshot = try await ArtifactScanner(locator: locator).scan(configuration: ScanConfiguration(
            automaticDiscoveryRoot: fixture.url, explicitRoots: [fixture.main]
        ))
        XCTAssertEqual(snapshot.artifacts.map(\.projectPath), [linked.path])
        XCTAssertEqual(snapshot.errorsSkipped, 1)
    }

    func testPrivacyAndExplicitRootBoundaries() throws {
        let home = URL(fileURLWithPath: "/Users/example")
        let configuration = ScanConfiguration(automaticDiscoveryRoot: home, explicitRoots: [home.appendingPathComponent("Documents/allowed")])
        for path in ["/Users/example/Documents/private", "/Users/example/Library/worktree", "/Users/example/target/worktree", "/Users/example-other/tree", "/external/tree", home.path] {
            XCTAssertNil(ProjectLocator.worktreeScope(for: URL(fileURLWithPath: path), configuration: configuration), path)
        }
        XCTAssertNotNil(ProjectLocator.worktreeScope(for: home.appendingPathComponent(".hidden/tree"), configuration: configuration))
        XCTAssertNotNil(ProjectLocator.worktreeScope(for: home.appendingPathComponent("Documents/allowed/tree"), configuration: configuration))
    }

    func testProtectedWorktreeRequiresExplicitSelection() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let linked = try fixture.worktree("Documents/private")
        try fixture.artifact(in: linked)
        let locator = ProjectLocator(indexedPaths: { _ in [fixture.main.appendingPathComponent(".git").path] })
        let scanner = ArtifactScanner(locator: locator)
        let automatic = try await scanner.scan(configuration: fixture.configuration)
        XCTAssertTrue(automatic.artifacts.isEmpty)
        let explicit = try await scanner.scan(configuration: ScanConfiguration(automaticDiscoveryRoot: fixture.url, explicitRoots: [linked]))
        XCTAssertEqual(explicit.artifacts.count, 1)
    }

    func testStaleAndRedirectedRegistrationsAreIgnored() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let stale = try fixture.worktree("stale")
        try FileManager.default.removeItem(at: stale)
        let redirected = try fixture.worktree("redirected")
        let moved = fixture.url.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: redirected, to: moved)
        try fixture.artifact(in: moved)
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: moved)
        let locator = ProjectLocator(indexedPaths: { _ in [fixture.main.appendingPathComponent(".git").path] })
        let snapshot = try await ArtifactScanner(locator: locator).scan(configuration: fixture.configuration)
        XCTAssertTrue(snapshot.artifacts.isEmpty)
    }

    func testSeparateGitDirectoryIsNotLabeledAsWorktree() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let checkout = fixture.url.appendingPathComponent("separate")
        try fixture.git(["init", "--separate-git-dir", fixture.url.appendingPathComponent("metadata").path, checkout.path])
        let repository = try XCTUnwrap(GitRepository.at(checkout))
        XCTAssertFalse(repository.isLinkedWorktree)
    }

    func testSubmoduleIsNotLabeledAsWorktree() throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        try fixture.git(["-C", fixture.main.path, "-c", "protocol.file.allow=always", "submodule", "add", fixture.main.path, "child"])
        let repository = try XCTUnwrap(GitRepository.at(fixture.main.appendingPathComponent("child")))
        XCTAssertFalse(repository.isLinkedWorktree)
    }

    func testBareRepositoryDiscoversItsWorktrees() async throws {
        let fixture = try GitFixture()
        defer { fixture.remove() }
        let bare = fixture.url.appendingPathComponent("bare.git")
        try fixture.git(["clone", "--bare", fixture.main.path, bare.path])
        let linked = fixture.url.appendingPathComponent("bare-checkout")
        try fixture.git(["-C", bare.path, "worktree", "add", "--detach", linked.path, "HEAD"])
        try fixture.artifact(in: linked)
        let locator = ProjectLocator(indexedPaths: { _ in [] })
        let snapshot = try await ArtifactScanner(locator: locator).scan(configuration: ScanConfiguration(automaticDiscoveryRoot: fixture.url, explicitRoots: [bare]))
        XCTAssertEqual(snapshot.artifacts.map(\.projectPath), [linked.path])
        XCTAssertEqual(snapshot.artifacts.first?.worktreeName, "bare-checkout")
    }
}

private final class GitFixture: @unchecked Sendable {
    let url: URL
    let main: URL
    var configuration: ScanConfiguration { ScanConfiguration(automaticDiscoveryRoot: url, explicitRoots: []) }

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSiftGitTests-\(UUID().uuidString)")
        main = url.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try git(["init", main.path])
        try git(["-C", main.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture"])
    }

    func worktree(_ path: String) throws -> URL {
        let root = url.appendingPathComponent(path)
        try git(["-C", main.path, "worktree", "add", "--detach", root.path, "HEAD"])
        return root
    }

    func artifact(in root: URL) throws {
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("[workspace]".utf8).write(to: root.appendingPathComponent("Cargo.toml"))
        try Data(repeating: 42, count: 4_096).write(to: target.appendingPathComponent("output"))
    }

    func git(_ arguments: [String]) throws {
        _ = try ScanProcess.output(executable: "/usr/bin/git", arguments: ["-c", "core.hooksPath=/dev/null"] + arguments)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
