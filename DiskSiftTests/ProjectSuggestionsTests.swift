import XCTest
@testable import DiskSift

final class ProjectSuggestionsTests: XCTestCase {
    func testSuggestionsGroupNamedWorkspacesAndExcludeProtectedFolders() throws {
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
        XCTAssertTrue(result.suggestions.contains { $0.url.path == home.appendingPathComponent("Work").path })
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
        XCTAssertEqual(Set(result.suggestions.map { $0.url.path }), [home.appendingPathComponent("Clients").path, home.appendingPathComponent("Experiments").path])
        XCTAssertEqual(result.suggestions.first { $0.url.path == home.appendingPathComponent("Clients").path }?.projects, 1)
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
                if update.suggestions.contains(where: { $0.url.path == home.appendingPathComponent("Clients").path }) { appeared.fulfill() }
            }
        }
        await fulfillment(of: [appeared], timeout: 5)
        task.cancel()
        let stopped = await task.value
        XCTAssertEqual(stopped.suggestions.map { $0.url.path }, [home.appendingPathComponent("Clients").path])
    }
}

extension ProjectSuggestionsTests {
    func testRepositoryClustersTolerateSupportingFilesAndFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HemdiffFind-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: home) }
        for folder in ["AutoProjects/first", "AutoProjects/second", "Mixed/first", "Mixed/second",
                       "Projects/first", "Projects/second", "Clients/solo", "Other/first", "Other/second"] {
            let repo = home.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
            try Data("ref: refs/heads/main\n".utf8).write(to: repo.appendingPathComponent(".git/HEAD"))
        }
        try Data("Notes".utf8).write(to: home.appendingPathComponent("AutoProjects/README.md"))
        try Data().write(to: home.appendingPathComponent("Mixed/taxes.pdf"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Projects/Photos"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("Other/shortcut"), withDestinationURL: home.appendingPathComponent("AutoProjects"))
        let result = try ProjectSuggestions(home: home, locator: ProjectLocator(indexedPaths: { _ in [] })).discover()
        let workspace = try XCTUnwrap(result.suggestions.first { $0.url.lastPathComponent == "AutoProjects" })
        XCTAssertEqual(workspace.projects, 2)
        XCTAssertTrue(workspace.isWorkspace)
        XCTAssertEqual(Set(workspace.projectURLs.map(\.lastPathComponent)), ["first", "second"])
        for folder in ["Mixed", "Projects", "Other", "Clients"] {
            XCTAssertTrue(result.suggestions.contains { $0.url.path == home.appendingPathComponent(folder).path }, folder)
        }
        XCTAssertFalse(result.suggestions.contains { $0.url.path == home.appendingPathComponent("Clients/solo").path })
        XCTAssertFalse(result.suggestions.contains { $0.url.path == home.path })
    }

    func testParentOptionNeverOffersHomeOrProtectedFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HemdiffFind-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: home) }
        for folder in ["Clients/solo", "Documents/private"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let finder = ProjectSuggestions(home: home)
        XCTAssertEqual(finder.parentOption(for: home.appendingPathComponent("Clients/solo"))?.path, home.appendingPathComponent("Clients").path)
        XCTAssertNil(finder.parentOption(for: home.appendingPathComponent("Clients")))
        XCTAssertNil(finder.parentOption(for: home.appendingPathComponent("Documents/private")))
    }
}

extension ProjectSuggestionsTests {
    func testSingleProjectContainerNameAndGoCacheExclusion() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HemdiffFind-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: home) }
        for path in ["AutoProjects/fraktur", "go/pkg/mod/example.org/dependency@v1", "Work/mod"] {
            let folder = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("go.mod"))
        }
        let cacheMarker = home.appendingPathComponent("go/pkg/mod/example.org/dependency@v1/go.mod").path
        let result = try ProjectSuggestions(home: home, locator: ProjectLocator(indexedPaths: { _ in [cacheMarker] })).discover()
        XCTAssertEqual(Set(result.suggestions.map { $0.url.path }), [
            home.appendingPathComponent("AutoProjects").path, home.appendingPathComponent("Work").path
        ])
        XCTAssertTrue(result.suggestions.first { $0.url.lastPathComponent == "AutoProjects" }?.isWorkspace == true)
    }
}

extension ProjectSuggestionsTests {
    func testShallowWorkspaceTheoryAcrossLayouts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("HemdiffFind-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: home) }
        func repo(_ path: String) throws {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
            try Data("ref: refs/heads/main\n".utf8).write(to: url.appendingPathComponent(".git/HEAD"))
        }
        for path in ["MarketResearch/portfolio/guide", "MarketResearch/service-federation",
                     "Learning/navier-stokes", "ghq/github.com/company/one", "ghq/github.com/company/two",
                     "UnusualName/company/one", "UnusualName/company/two", "Monorepo",
                     "Personal/old-project", "SinglePurpose/tool"] { try repo(path) }
        for path in ["Personal/Photos", "Personal/Invoices", "Personal/Travel", "MarketResearch/notes"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data().write(to: home.appendingPathComponent("MarketResearch/plan.pdf"))
        let nested = home.appendingPathComponent("Monorepo/packages/module")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("package.json"))
        let result = try ProjectSuggestions(home: home, locator: ProjectLocator(indexedPaths: { _ in [nested.appendingPathComponent("package.json").path] })).discover()
        XCTAssertEqual(Set(result.suggestions.map { $0.url.path }), Set([
            "MarketResearch", "Learning", "ghq", "UnusualName", "Monorepo", "Personal/old-project", "SinglePurpose"
        ].map { home.appendingPathComponent($0).path }))
        XCTAssertEqual(result.suggestions.first { $0.url.lastPathComponent == "Monorepo" }?.projects, 1)
        XCTAssertFalse(result.suggestions.first { $0.url.lastPathComponent == "Monorepo" }!.isWorkspace)
    }
}
