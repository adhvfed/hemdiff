import Foundation
import XCTest
@testable import DiskSift

final class ProjectLocatorTests: XCTestCase {
    func testAutomaticDiscoveryFindsXcodeDerivedDataChildren() throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }

        let derivedData = ProjectLocator.xcodeDerivedDataRoot(in: fixture.url)
        let project = derivedData.appendingPathComponent("DiskSift-ABC123", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let discovery = try ProjectLocator().locate(
            configuration: ScanConfiguration(
                automaticDiscoveryRoot: fixture.url,
                explicitRoots: []
            )
        )

        let marker = try XCTUnwrap(
            discovery.markers.first { $0.kind == .xcodeDerivedData }
        )
        XCTAssertEqual(marker.projectURL, derivedData.standardizedFileURL)
        XCTAssertEqual(marker.artifactURL, project.standardizedFileURL)
    }

    func testAutomaticDiscoveryExcludesPrivacyManagedHomeFolders() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        for folder in ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures"] {
            let marker = home
                .appendingPathComponent(folder)
                .appendingPathComponent("ArbitraryProject")
                .appendingPathComponent("Cargo.toml")
            XCTAssertTrue(
                ProjectLocator.isAutomaticallyExcluded(marker, home: home),
                "Expected \(folder) to require explicit user selection"
            )
        }
    }

    func testAutomaticDiscoveryDoesNotAssumeProjectContainerName() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let arbitrary = home
            .appendingPathComponent("anything-at-all")
            .appendingPathComponent("nested")
            .appendingPathComponent("feature")
            .appendingPathComponent("package.json")

        XCTAssertFalse(ProjectLocator.isAutomaticallyExcluded(arbitrary, home: home))
    }

    func testAutomaticDiscoveryRejectsDependencyAndBuildMarkers() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let dependency = home
            .appendingPathComponent("wild-name")
            .appendingPathComponent("node_modules")
            .appendingPathComponent("dependency")
            .appendingPathComponent("package.json")
        let buildOutput = home
            .appendingPathComponent("another-name")
            .appendingPathComponent("target")
            .appendingPathComponent("checkout")
            .appendingPathComponent("Cargo.toml")

        XCTAssertTrue(ProjectLocator.isAutomaticallyExcluded(dependency, home: home))
        XCTAssertTrue(ProjectLocator.isAutomaticallyExcluded(buildOutput, home: home))
    }

    func testAutomaticDiscoveryAllowsValidatedArtifactDirectories() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let target = home
            .appendingPathComponent("Projects")
            .appendingPathComponent("app")
            .appendingPathComponent("target")

        XCTAssertFalse(
            ProjectLocator.isAutomaticallyExcluded(
                target,
                home: home,
                allowingArtifactKind: .rustTarget
            )
        )

        let nestedTarget = target
            .appendingPathComponent("checkout")
            .appendingPathComponent("target")
        XCTAssertTrue(
            ProjectLocator.isAutomaticallyExcluded(
                nestedTarget,
                home: home,
                allowingArtifactKind: .rustTarget
            )
        )
    }
}

private final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSiftLocatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
