import Foundation
import XCTest
@testable import DiskSift

final class ArtifactReclaimerTests: XCTestCase {
    func testValidationRejectsSymlinkAncestorEvenWhenArtifactIdentityMatches() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("DiskSiftAncestor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let project = fixture.appendingPathComponent("original/parent/project")
        let target = project.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("[workspace]".utf8).write(to: project.appendingPathComponent("Cargo.toml"))
        let artifact = Artifact(kind: .rustTarget, path: target.path, projectPath: project.path,
                                allocatedBytes: 0, createdAt: nil, modifiedAt: nil,
                                fileIdentity: try ArtifactFileIdentity.capture(at: target))
        let original = fixture.appendingPathComponent("original")
        let moved = fixture.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: moved)
        XCTAssertEqual(try ArtifactFileIdentity.capture(at: target), artifact.fileIdentity)
        XCTAssertThrowsError(try ArtifactReclaimer().validate(artifact)) {
            XCTAssertEqual($0 as? ReclaimValidationError, .symbolicLink)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("parent/project/target").path))
    }

    func testValidationAcceptsXcodeDerivedDataChildInKnownContainer() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSiftReclaim-\(UUID().uuidString)", isDirectory: true)
        let container = ProjectLocator.xcodeDerivedDataRoot(in: fixture)
        let project = container.appendingPathComponent("DiskSift-ABC123", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let artifact = Artifact(
            kind: .xcodeDerivedData,
            path: project.path,
            projectPath: container.path,
            allocatedBytes: 0,
            createdAt: nil,
            modifiedAt: nil,
            fileIdentity: try ArtifactFileIdentity.capture(at: project)
        )

        XCTAssertNoThrow(try ArtifactReclaimer(homeDirectory: fixture).validate(artifact))
    }

    func testValidationRejectsLookalikeXcodeDerivedDataContainer() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSiftReclaim-\(UUID().uuidString)", isDirectory: true)
        let derivedData = fixture
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        let project = derivedData.appendingPathComponent("DiskSift-ABC123", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let artifact = Artifact(
            kind: .xcodeDerivedData,
            path: project.path,
            projectPath: derivedData.path,
            allocatedBytes: 0,
            createdAt: nil,
            modifiedAt: nil,
            fileIdentity: try ArtifactFileIdentity.capture(at: project)
        )

        XCTAssertThrowsError(try ArtifactReclaimer().validate(artifact)) { error in
            XCTAssertEqual(error as? ReclaimValidationError, .unexpectedPath)
        }
    }

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

    func testReclaimPermanentlyDeletesRustAndNodeArtifacts() async throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSiftReclaim-\(UUID().uuidString)", isDirectory: true)
        let rustProject = fixture.appendingPathComponent("RustProject", isDirectory: true)
        let nodeProject = fixture.appendingPathComponent("NodeProject", isDirectory: true)
        let target = rustProject.appendingPathComponent("target", isDirectory: true)
        let nodeModules = nodeProject.appendingPathComponent("node_modules", isDirectory: true)

        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try Data("[package]".utf8).write(to: rustProject.appendingPathComponent("Cargo.toml"))
        try Data("{}".utf8).write(to: nodeProject.appendingPathComponent("package.json"))
        try Data("artifact".utf8).write(to: target.appendingPathComponent("app"))
        try Data("dependency".utf8).write(to: nodeModules.appendingPathComponent("package"))
        defer { try? FileManager.default.removeItem(at: fixture) }

        let rustArtifact = Artifact(
            kind: .rustTarget,
            path: target.path,
            projectPath: rustProject.path,
            allocatedBytes: 8,
            createdAt: nil,
            modifiedAt: nil,
            fileIdentity: try ArtifactFileIdentity.capture(at: target)
        )
        let nodeArtifact = Artifact(
            kind: .nodeModules,
            path: nodeModules.path,
            projectPath: nodeProject.path,
            allocatedBytes: 10,
            createdAt: nil,
            modifiedAt: nil,
            fileIdentity: try ArtifactFileIdentity.capture(at: nodeModules)
        )

        let result = await ArtifactReclaimer().reclaim([rustArtifact, nodeArtifact])

        XCTAssertEqual(result.reclaimedIDs, [rustArtifact.id, nodeArtifact.id])
        XCTAssertEqual(result.reclaimedBytes, 18)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nodeModules.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rustProject.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nodeProject.path))
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
