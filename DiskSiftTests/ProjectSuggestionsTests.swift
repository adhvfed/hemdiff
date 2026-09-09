import XCTest
@testable import DiskSift

final class ProjectSuggestionsTests: XCTestCase {
    func testSuggestionsGroupCommonFoldersButNotUnrelatedParents() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HemdiffFind-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: home) }
        func marker(_ path: String) throws -> URL {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url)
            return url
        }
        _ = try marker("Projects/one/package.json")
        _ = try marker("Projects/two/pyproject.toml")
        _ = try marker("Projects/one/node_modules/dependency/package.json")
        let separate = try marker("Work/customer/package.json")
        let personal = try marker("Documents/personal/package.json")
        let result = try ProjectSuggestions(home: home, locator: ProjectLocator(indexedPaths: { _ in [separate.path, personal.path] })).discover()
        XCTAssertEqual(result.suggestions.count, 2)
        XCTAssertEqual(result.suggestions.first { $0.url.lastPathComponent == "Projects" }?.projects, 2)
        XCTAssertTrue(result.suggestions.contains { $0.url == separate.deletingLastPathComponent() })
        XCTAssertFalse(result.suggestions.contains { $0.url == home.appendingPathComponent("Work") })
        XCTAssertFalse(result.limited)
    }

    func testBudgetAndSymlinkExclusion() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HemdiffFind-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("Projects/one")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("Cargo.toml"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Code"), withDestinationURL: home.appendingPathComponent("Projects"))
        let emptyIndex = ProjectLocator(indexedPaths: { _ in [] })
        let result = try ProjectSuggestions(home: home, locator: emptyIndex).discover()
        XCTAssertEqual(result.suggestions.count, 1)
        XCTAssertEqual(result.suggestions.first?.url.lastPathComponent, "Projects")
        XCTAssertTrue(try ProjectSuggestions(home: home, locator: emptyIndex, entryLimit: 0).discover().limited)
    }
}
