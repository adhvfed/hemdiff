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
        XCTAssertFalse(result.indexUnavailable)
    }

    func testSymlinkExclusion() throws {
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
    }
}

extension ProjectSuggestionsTests {
    func testUnindexedGitAndDeepProjectsOutsideCommonNames() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HemdiffFind-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: home) }
        let repository = home.appendingPathComponent("Clients/website")
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: repository.appendingPathComponent(".git/HEAD"))
        let deep = home.appendingPathComponent("Experiments/a/b/c/d/e/f/engine")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data().write(to: deep.appendingPathComponent("Cargo.toml"))
        // A nested manifest is already covered by the enclosing repository.
        let nested = repository.appendingPathComponent("packages/child")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("package.json"))
        for excluded in ["Documents/private", ".secrets/project", "Clients/node_modules/dependency", "Clients/Tool.app/Contents/project"] {
            let url = home.appendingPathComponent(excluded)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data().write(to: url.appendingPathComponent("package.json"))
        }
        let result = try ProjectSuggestions(home: home, locator: ProjectLocator(indexedPaths: { _ in [] })).discover()
        XCTAssertEqual(Set(result.suggestions.map { $0.url.path }), [repository.path, deep.path])
        XCTAssertEqual(result.suggestions.first { $0.url.path == repository.path }?.projects, 1)
    }

    func testIndexedGitHeadAndDuplicateMarkers() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HemdiffFind-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = home.appendingPathComponent(".workspace/repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: repo.appendingPathComponent(".git/HEAD"))
        let result = try ProjectSuggestions(home: home, locator: ProjectLocator(indexedPaths: { _ in
            [repo.appendingPathComponent(".git/HEAD").path, repo.appendingPathComponent(".git").path]
        })).discover()
        XCTAssertEqual(result.suggestions.map { $0.url.path }, [repo.path])
        XCTAssertEqual(result.suggestions.first?.projects, 1)
    }

    func testLiveResultsAndCancellationWhileSpotlightIsBusy() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HemdiffFind-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("Clients/repo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data().write(to: project.appendingPathComponent("package.json"))
        let appeared = expectation(description: "Folder results appear before Spotlight finishes")
        appeared.assertForOverFulfill = false
        let finder = ProjectSuggestions(home: home, locator: ProjectLocator(indexedPaths: { _ in
            while true {
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.01)
            }
        }))
        let task = Task {
            await finder.find { update in
                if update.suggestions.contains(where: { $0.url.path == project.path }) { appeared.fulfill() }
            }
        }
        await fulfillment(of: [appeared], timeout: 5)
        task.cancel()
        let stopped = await task.value
        XCTAssertEqual(stopped.suggestions.map { $0.url.path }, [project.path])
    }
}
