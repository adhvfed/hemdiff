import Foundation
import XCTest
@testable import DiskSift

final class ArtifactReclaimerTests: XCTestCase {
    func testValidationRejectsMarkerlessFolder() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSiftReclaim-\(UUID().uuidString)", isDirectory: true)
        let target = project.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        let artifact = Artifact(
            kind: .rustTarget,
            path: target.path,
            projectPath: project.path,
            allocatedBytes: 0,
            createdAt: nil,
            modifiedAt: nil
        )

        XCTAssertThrowsError(try ArtifactReclaimer().validate(artifact)) { error in
            XCTAssertEqual(error as? ReclaimValidationError, .missingProjectMarker)
        }
    }

    func testValidationAcceptsMatchingProject() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSiftReclaim-\(UUID().uuidString)", isDirectory: true)
        let target = project.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("[package]".utf8).write(to: project.appendingPathComponent("Cargo.toml"))
        defer { try? FileManager.default.removeItem(at: project) }

        let artifact = Artifact(
            kind: .rustTarget,
            path: target.path,
            projectPath: project.path,
            allocatedBytes: 0,
            createdAt: nil,
            modifiedAt: nil
        )

        XCTAssertNoThrow(try ArtifactReclaimer().validate(artifact))
    }
}
