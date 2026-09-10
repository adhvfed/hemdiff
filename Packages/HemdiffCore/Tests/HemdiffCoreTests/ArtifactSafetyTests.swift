import Foundation
import XCTest
@testable import HemdiffCore

final class ArtifactSafetyTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testProjectMarkersMustBeRegularFilesAndNotLinks() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("package.json")
        XCTAssertFalse(ArtifactRules.matches(.nextBuild, project: root))
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        XCTAssertFalse(ArtifactRules.matches(.nextBuild, project: root))
        try FileManager.default.removeItem(at: marker)
        let external = root.appendingPathComponent("external.json")
        try Data("{}".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: external)
        XCTAssertFalse(ArtifactRules.matches(.nextBuild, project: root))
        try FileManager.default.removeItem(at: marker)
        try Data("{}".utf8).write(to: marker)
        XCTAssertTrue(ArtifactRules.matches(.nextBuild, project: root))
    }

    func testTerraformRequiresSourceAndLockfile() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(".terraform.lock.hcl"))
        XCTAssertFalse(ArtifactRules.matches(.terraformProviders, project: root))
        try Data().write(to: root.appendingPathComponent("main.tofu"))
        XCTAssertTrue(ArtifactRules.matches(.terraformProviders, project: root))
    }

    func testContainmentUsesComponentsAndRejectsAncestorLinks() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(PathSafety.contains(URL(fileURLWithPath: root.path + "-other"), in: root))
        XCTAssertTrue(PathSafety.contains(root.appendingPathComponent("a"), in: root))
        let actual = root.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        XCTAssertTrue(PathSafety.hasSymbolicLink(in: link.appendingPathComponent("child")))
        XCTAssertFalse(PathSafety.isDirectory(link))
    }

    func testReplacedDirectoryIdentityRejectsReclamation() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("package.json"))
        let output = root.appendingPathComponent(".next")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let identity = try ArtifactFileIdentity.capture(at: output)
        let artifact = Artifact(kind: .nextBuild, path: output.path, projectPath: root.path,
                                allocatedBytes: 0, createdAt: nil, modifiedAt: nil, fileIdentity: identity)
        try ArtifactReclaimer().validate(artifact)
        try FileManager.default.moveItem(at: output, to: root.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ArtifactReclaimer().validate(artifact)) {
            XCTAssertEqual($0 as? ReclaimValidationError, .changedSinceScan)
        }
    }
}
