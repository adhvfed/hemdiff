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
            modifiedAt: nil,
            fileIdentity: try ArtifactFileIdentity.capture(at: target)
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
            modifiedAt: nil,
            fileIdentity: try ArtifactFileIdentity.capture(at: target)
        )

        XCTAssertNoThrow(try ArtifactReclaimer().validate(artifact))
    }

    func testValidationRejectsArtifactOutsideScannedProject() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSiftReclaim-\(UUID().uuidString)", isDirectory: true)
        let scannedProject = fixture.appendingPathComponent("Scanned", isDirectory: true)
        let otherProject = fixture.appendingPathComponent("Other", isDirectory: true)
        let otherTarget = otherProject.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: scannedProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherTarget, withIntermediateDirectories: true)
        try Data("[package]".utf8).write(to: otherProject.appendingPathComponent("Cargo.toml"))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let artifact = Artifact(
            kind: .rustTarget,
            path: otherTarget.path,
            projectPath: scannedProject.path,
            allocatedBytes: 0,
            createdAt: nil,
            modifiedAt: nil,
            fileIdentity: try ArtifactFileIdentity.capture(at: otherTarget)
        )

        XCTAssertThrowsError(try ArtifactReclaimer().validate(artifact)) { error in
            XCTAssertEqual(error as? ReclaimValidationError, .unexpectedPath)
        }
    }

    func testValidationRejectsFolderReplacedSinceScan() throws {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSiftReclaim-\(UUID().uuidString)", isDirectory: true)
        let target = project.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("[package]".utf8).write(to: project.appendingPathComponent("Cargo.toml"))
        let scannedIdentity = try ArtifactFileIdentity.capture(at: target)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: project) }

        let artifact = Artifact(
            kind: .rustTarget,
            path: target.path,
            projectPath: project.path,
            allocatedBytes: 0,
            createdAt: nil,
            modifiedAt: nil,
            fileIdentity: scannedIdentity
        )

        XCTAssertThrowsError(try ArtifactReclaimer().validate(artifact)) { error in
            XCTAssertEqual(error as? ReclaimValidationError, .changedSinceScan)
        }
    }

    func testValidationRejectsSymbolicLinkArtifact() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSiftReclaim-\(UUID().uuidString)", isDirectory: true)
        let project = fixture.appendingPathComponent("Project", isDirectory: true)
        let actualTarget = fixture.appendingPathComponent("ActualTarget", isDirectory: true)
        let target = project.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: actualTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: actualTarget)
        try Data("[package]".utf8).write(to: project.appendingPathComponent("Cargo.toml"))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let artifact = Artifact(
            kind: .rustTarget,
            path: target.path,
            projectPath: project.path,
            allocatedBytes: 0,
            createdAt: nil,
            modifiedAt: nil,
            fileIdentity: try ArtifactFileIdentity.capture(at: target)
        )

        XCTAssertThrowsError(try ArtifactReclaimer().validate(artifact)) { error in
            XCTAssertEqual(error as? ReclaimValidationError, .symbolicLink)
        }
    }

    func testValidationRejectsSymbolicLinkProjectMarker() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSiftReclaim-\(UUID().uuidString)", isDirectory: true)
        let project = fixture.appendingPathComponent("Project", isDirectory: true)
        let target = project.appendingPathComponent("target", isDirectory: true)
        let markerSource = fixture.appendingPathComponent("Cargo-source.toml")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("[package]".utf8).write(to: markerSource)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("Cargo.toml"),
            withDestinationURL: markerSource
        )
        defer { try? FileManager.default.removeItem(at: fixture) }

        let artifact = Artifact(
            kind: .rustTarget,
            path: target.path,
            projectPath: project.path,
            allocatedBytes: 0,
            createdAt: nil,
            modifiedAt: nil,
            fileIdentity: try ArtifactFileIdentity.capture(at: target)
        )

        XCTAssertThrowsError(try ArtifactReclaimer().validate(artifact)) { error in
            XCTAssertEqual(error as? ReclaimValidationError, .missingProjectMarker)
        }
    }
}
