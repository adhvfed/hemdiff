import Foundation

struct ProjectSuggestion: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let projects: Int
    let worktrees: Int
}

struct ProjectSuggestionResult: Sendable {
    let suggestions: [ProjectSuggestion]
    let limited: Bool
    let indexUnavailable: Bool
}

struct ProjectSuggestions: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var locator = ProjectLocator()
    var entryLimit = 20_000
    static let commonNames = ["Projects", "Developer", "Development", "Code", "src", "Source", "Repos", "Repositories"]
    private static let pruned: Set<String> = [".git", "node_modules", "target", "build", "dist", ".next", ".build", ".turbo", ".terraform", ".venv", "venv", "vendor", ".cache", ".pytest_cache", ".ruff_cache", ".mypy_cache"]
    private static let manifests = Set(ArtifactKind.allCases.flatMap(\.markerNames) + ["go.mod", "requirements.txt", "Gemfile", "CMakeLists.txt", "composer.json"])

    func find() async throws -> ProjectSuggestionResult {
        let worker = Task.detached(priority: .utility) { try discover() }
        let timeout = Task {
            try await Task.sleep(for: .seconds(20))
            worker.cancel()
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    func discover() throws -> ProjectSuggestionResult {
        let roots = Self.commonNames.map { home.appendingPathComponent($0).standardizedFileURL }.filter(PathSafety.isDirectory)
        var projects = Set<URL>(), worktrees = Set<URL>()
        var visited = 0, limited = false, depthLimited = false, indexUnavailable = false
        func allowed(_ url: URL) -> Bool {
            url.standardizedFileURL != home.standardizedFileURL &&
            !ProjectLocator.isAutomaticallyExcluded(url, home: home) &&
            !url.pathComponents.contains(where: Self.pruned.contains) && PathSafety.isDirectory(url)
        }
        func inspect(_ url: URL) {
            guard allowed(url) else { return }
            let hasMarker = Self.manifests.contains { name in
                let marker = url.appendingPathComponent(name)
                return !PathSafety.hasSymbolicLink(in: marker) && (try? marker.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            if hasMarker || GitRepository.at(url) != nil { projects.insert(url.standardizedFileURL) }
        }
        for root in roots {
            try Task.checkCancellation()
            inspect(root)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsPackageDescendants]) else { continue }
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                visited += 1
                if visited > entryLimit { limited = true; break }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if enumerator.level > 5 { depthLimited = true }
                if values?.isSymbolicLink == true || Self.pruned.contains(url.lastPathComponent) || enumerator.level > 5 {
                    enumerator.skipDescendants(); continue
                }
                if values?.isDirectory == true { inspect(url) }
            }
            if limited { break }
        }
        if !limited { do {
            for path in try locator.indexedPaths(home) {
                try Task.checkCancellation()
                visited += 1
                if visited > entryLimit { limited = true; break }
                inspect(URL(fileURLWithPath: path).deletingLastPathComponent())
            }
        } catch is CancellationError { throw CancellationError() }
        catch { indexUnavailable = true }
        }
        var seenCommon = Set<String>()
        for project in projects.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            guard let repository = GitRepository.at(project), seenCommon.insert(repository.commonDirectory.path).inserted else { continue }
            for checkout in (try? repository.registeredWorktrees()) ?? [] {
                try Task.checkCancellation()
                guard allowed(checkout), let linked = GitRepository.at(checkout), linked.commonDirectory.path == repository.commonDirectory.path else { continue }
                projects.insert(checkout.standardizedFileURL)
                if checkout.standardizedFileURL != repository.root.standardizedFileURL { worktrees.insert(checkout.standardizedFileURL) }
            }
        }
        // Only familiar project containers are grouped. Elsewhere suggest the exact project.
        let grouped = Dictionary(grouping: projects) { project in roots.first { PathSafety.contains(project, in: $0) } ?? project }
        let suggestions = grouped.map { root, found in
            ProjectSuggestion(url: root, projects: found.count, worktrees: found.filter(worktrees.contains).count)
        }.sorted { $0.url.path < $1.url.path }
        return ProjectSuggestionResult(suggestions: suggestions, limited: limited || depthLimited, indexUnavailable: indexUnavailable)
    }
}
