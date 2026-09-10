import Foundation
import XCTest
@testable import DiskSift

final class ArtifactRulesTests: XCTestCase {
    func testDiscoversToolOutputsAndSeparatesLogs() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(ArtifactKind, String)] = [
            (.nextBuild, "package.json"), (.turboCache, "turbo.json"),
            (.terraformProviders, ".terraform.lock.hcl"), (.pytestCache, "pyproject.toml"),
            (.ruffCache, "ruff.toml"), (.mypyCache, "mypy.ini"), (.mavenTarget, "pom.xml"), (.gradleBuild, "build.gradle.kts")
        ]
        for (kind, marker) in cases {
            let project = root.appendingPathComponent(kind.rawValue)
            try file(project.appendingPathComponent(marker))
            if kind == .terraformProviders { try file(project.appendingPathComponent("main.tf")) }
            try file(project.appendingPathComponent(kind.folderName).appendingPathComponent("output"))
        }
        try file(root.appendingPathComponent("server.log"))
        try file(root.appendingPathComponent("server.log.1.gz"))
        try file(root.appendingPathComponent("ordinary/build/output"))
        let scan = try await ArtifactScanner().scan(roots: [root])
        XCTAssertEqual(Set(scan.artifacts.map(\.kind)), Set(cases.map(\.0)))
        XCTAssertEqual(scan.content.summaries.first { $0.kind == .logs }?.count, 2)
        XCTAssertFalse(scan.content.summaries.flatMap(\.largestItems).contains { $0.path.contains(".turbo/cache/") })
        XCTAssertFalse(scan.content.summaries.flatMap(\.largestItems).contains { $0.path.contains(".terraform/providers/") })
        XCTAssertTrue(scan.content.summaries.flatMap(\.largestItems).contains { $0.path.contains("ordinary/build/") })
    }

    func testProviderCleanupPreservesStateLockAndBackendMetadata() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["main.tf", ".terraform.lock.hcl", "terraform.tfstate", ".terraform/terraform.tfstate", ".terraform/environment", ".terraform/providers/registry/provider"] {
            try file(root.appendingPathComponent(path))
        }
        let scan = try await ArtifactScanner().scan(roots: [root])
        let artifact = try XCTUnwrap(scan.artifacts.first { $0.kind == .terraformProviders })
        let service = InteractiveCleanup(activity: IdleCleanupTestActivity(), quietInterval: 0, coordinationDirectory: root.appendingPathComponent("coordination"))
        let result = service.execute(try service.prepare([artifact]))
        XCTAssertEqual(result.reclaimedIDs, [artifact.id])
        for path in ["main.tf", ".terraform.lock.hcl", "terraform.tfstate", ".terraform/terraform.tfstate", ".terraform/environment"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), path)
        }
    }

    func testRemovalOfOwnershipMarkerRejectsCleanup() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try file(root.appendingPathComponent("turbo.json"))
        try file(root.appendingPathComponent(".turbo/cache/output"))
        let scan = try await ArtifactScanner().scan(roots: [root])
        let artifact = try XCTUnwrap(scan.artifacts.first)
        try FileManager.default.removeItem(at: root.appendingPathComponent("turbo.json"))
        XCTAssertThrowsError(try ArtifactReclaimer().validate(artifact))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSiftRules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func file(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url)
    }
}
