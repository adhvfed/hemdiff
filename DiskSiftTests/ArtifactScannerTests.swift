import Foundation
import XCTest
@testable import DiskSift

final class ArtifactScannerTests: XCTestCase {
    func testFindsXcodeDerivedDataAndSwiftPackageBuildOutput() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let derivedDataProject = ProjectLocator
            .xcodeDerivedDataRoot(in: fixture.url)
            .appendingPathComponent("DiskSift-ABC123", isDirectory: true)
        try fixture.directory("Library/Developer/Xcode/DerivedData/DiskSift-ABC123/Build")
        try fixture.dataFile(
            "Library/Developer/Xcode/DerivedData/DiskSift-ABC123/Build/products.bin",
            byteCount: 4_096
        )

        _ = try fixture.directory("SwiftTool/.build/debug")
        try fixture.file("SwiftTool/Package.swift", contents: "// swift-tools-version: 5.9")
        try fixture.dataFile("SwiftTool/.build/debug/tool", byteCount: 2_048)

        let snapshot = try await ArtifactScanner().scan(
            configuration: ScanConfiguration(
                automaticDiscoveryRoot: fixture.url,
                explicitRoots: [fixture.url]
            )
        )

        XCTAssertTrue(snapshot.artifacts.contains { $0.kind == .xcodeDerivedData })
        XCTAssertTrue(snapshot.artifacts.contains { $0.kind == .swiftBuild })
        XCTAssertEqual(
            snapshot.artifacts.filter { $0.kind == .xcodeDerivedData }.count,
            1
        )
        XCTAssertEqual(
            snapshot.artifacts.filter { $0.kind == .swiftBuild }.count,
            1
        )
        XCTAssertGreaterThan(snapshot.artifactBytes, 0)
        XCTAssertEqual(
            snapshot.artifacts.first(where: { $0.kind == .xcodeDerivedData })?.projectPath,
            derivedDataProject.deletingLastPathComponent().path
        )
    }

    func testSkipsSymbolicLinksInsideKnownXcodeDerivedDataRoot() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let derivedData = ProjectLocator.xcodeDerivedDataRoot(in: fixture.url)
        try FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
        let outside = try fixture.directory("Outside")
        let linked = derivedData.appendingPathComponent("LinkedProject", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)

        let snapshot = try await ArtifactScanner().scan(
            configuration: ScanConfiguration(
                automaticDiscoveryRoot: fixture.url,
                explicitRoots: []
            )
        )

        XCTAssertFalse(snapshot.artifacts.contains { $0.path == linked.path })
    }

    func testFindsOnlyFoldersWithMatchingProjectMarkers() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let rust = try fixture.directory("Projects/Ferris/target/debug")
        try fixture.file("Projects/Ferris/Cargo.toml", contents: "[package]")
        try fixture.dataFile("Projects/Ferris/target/debug/app", byteCount: 8_192)

        _ = try fixture.directory("Projects/LooseTarget/target")
        try fixture.dataFile("Projects/LooseTarget/target/object.o", byteCount: 4_096)

        _ = try fixture.directory("Projects/Web/node_modules/pkg")
        try fixture.file("Projects/Web/package.json", contents: "{}")
        try fixture.dataFile("Projects/Web/node_modules/pkg/index.js", byteCount: 12_000)

        _ = rust
        let snapshot = try await ArtifactScanner().scan(roots: [fixture.url])

        XCTAssertEqual(snapshot.artifacts.count, 2)
        XCTAssertEqual(Set(snapshot.artifacts.map(\.kind)), [.rustTarget, .nodeModules])
        XCTAssertTrue(snapshot.artifacts.allSatisfy { $0.allocatedBytes > 0 })
        XCTAssertFalse(snapshot.artifacts.contains { $0.projectName == "LooseTarget" })
    }

    func testDoesNotFollowSymbolicLinks() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        _ = try fixture.directory("Project/target")
        try fixture.file("Project/Cargo.toml", contents: "[package]")
        try FileManager.default.createSymbolicLink(
            at: fixture.url.appendingPathComponent("Project/target/loop"),
            withDestinationURL: fixture.url
        )

        let snapshot = try await ArtifactScanner().scan(roots: [fixture.url])
        XCTAssertEqual(snapshot.artifacts.count, 1)
        XCTAssertLessThan(snapshot.directoriesVisited, 10)
    }

    func testNestedRootsAreRemoved() throws {
        let home = URL(fileURLWithPath: "/Users/example")
        let roots = ArtifactScanner.normalizedRoots([
            home.appendingPathComponent("Projects"),
            home,
            home.appendingPathComponent("Projects/App"),
            home,
        ])

        XCTAssertEqual(roots, [home])
    }

    func testCancellationPropagatesToDirectoryWalk() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        for index in 0..<2_000 {
            try fixture.dataFile("ManyFiles/\(index).bin", byteCount: 32)
        }

        let task = Task {
            try await ArtifactScanner().scan(roots: [fixture.url])
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testCategoryTotalsIncludeRecognizedArtifactBytes() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        _ = try fixture.directory("Code/App/node_modules/package")
        try fixture.file("Code/App/package.json", contents: "{}")
        try fixture.dataFile("Code/App/node_modules/package/blob", byteCount: 32_000)

        let snapshot = try await ArtifactScanner().scan(roots: [fixture.url])
        let code = try XCTUnwrap(snapshot.categories.first { $0.name == "Code" })
        let artifact = try XCTUnwrap(snapshot.artifacts.first)
        XCTAssertGreaterThanOrEqual(code.allocatedBytes, artifact.allocatedBytes)
    }

    func testFindsAndLabelsProjectInsideHiddenGitWorktreeContainer() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let worktree = ".worktrees/feature-cleanup"
        _ = try fixture.directory("\(worktree)/target/debug")
        try fixture.file("\(worktree)/Cargo.toml", contents: "[package]")
        try fixture.file(
            "\(worktree)/.git",
            contents: "gitdir: /tmp/main-repository/.git/worktrees/feature-cleanup\n"
        )
        try fixture.dataFile("\(worktree)/target/debug/app", byteCount: 2_048)

        let snapshot = try await ArtifactScanner().scan(roots: [fixture.url])
        let artifact = try XCTUnwrap(snapshot.artifacts.first)

        XCTAssertEqual(snapshot.artifacts.count, 1)
        XCTAssertEqual(artifact.projectName, "feature-cleanup")
        XCTAssertEqual(artifact.worktreeName, "feature-cleanup")
    }
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func directory(_ path: String) throws -> URL {
        let directory = url.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func file(_ path: String, contents: String) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: file)
    }

    func dataFile(_ path: String, byteCount: Int) throws {
        let file = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x4A, count: byteCount).write(to: file)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
