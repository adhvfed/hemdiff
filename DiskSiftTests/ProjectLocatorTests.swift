import Foundation
import XCTest
@testable import DiskSift

final class ProjectLocatorTests: XCTestCase {
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
}
