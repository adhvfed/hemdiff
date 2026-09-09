import Foundation

struct ProjectSuggestion: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let projectURLs: [URL]
    let worktreeURLs: [URL]
    var projects: Int { projectURLs.count }
    var worktrees: Int { worktreeURLs.count }
    var isWorkspace: Bool { !projectURLs.contains { $0.path == url.path } }
}

struct ProjectSuggestionResult: Sendable {
    let suggestions: [ProjectSuggestion]
    let indexUnavailable: Bool
    let foldersUnavailable: Bool
}

private enum ProjectSearchEvent: Sendable {
    case project(URL, worktree: Bool)
    case container(URL, children: Set<String>, mixed: Bool)
    case refresh
    case indexUnavailable
    case foldersUnavailable
}

struct ProjectSuggestions: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var locator = ProjectLocator()
    static let commonNames = ["Projects", "Developer", "Development", "Code", "src", "Source", "Repos", "Repositories"]
    static func isContainerName(_ name: String) -> Bool {
        commonNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame } ||
            name.lowercased().hasSuffix("projects")
    }

    private static let pruned: Set<String> = [".git", "node_modules", "target", "build", "dist", ".next", ".build", ".turbo", ".terraform", ".venv", "venv", "vendor", ".cache", ".pytest_cache", ".ruff_cache", ".mypy_cache"]
    private static let manifests = Set(ArtifactKind.allCases.flatMap(\.markerNames) + ["go.mod", "requirements.txt", "Gemfile", "CMakeLists.txt", "composer.json"])

    /// Independent sources publish into one stream. Cancellation reaches both the
    /// directory walk and mdfind; all results delivered before stopping are retained.
    func find(onUpdate: @escaping @Sendable (ProjectSuggestionResult) async -> Void = { _ in }) async -> ProjectSuggestionResult {
        let (stream, continuation) = AsyncStream<ProjectSearchEvent>.makeStream()
        let worker = Task.detached(priority: .utility) {
            let ticker = Task {
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(100))
                        continuation.yield(.refresh)
                    }
                } catch {}
            }
            defer { ticker.cancel() }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? searchFolders { continuation.yield($0) } }
                group.addTask { try? searchIndex { continuation.yield($0) } }
            }
            continuation.finish()
        }
        return await withTaskCancellationHandler {
            var collected = CollectedProjects(home: home)
            var lastUpdate: ContinuousClock.Instant?
            var dirty = false
            for await event in stream {
                collected.accept(event)
                if case .refresh = event {} else { dirty = true }
                if dirty && (lastUpdate == nil || lastUpdate!.duration(to: .now) >= .milliseconds(100)) {
                    await onUpdate(collected.result)
                    lastUpdate = .now
                    dirty = false
                }
            }
            worker.cancel()
            await worker.value
            await onUpdate(collected.result)
            return collected.result
        } onCancel: { worker.cancel() }
    }

    // Synchronous entry point for deterministic discovery tests.
    func discover() throws -> ProjectSuggestionResult {
        var collected = CollectedProjects(home: home)
        try searchFolders { collected.accept($0) }
        try searchIndex { collected.accept($0) }
        return collected.result
    }

    func parentOption(for url: URL) -> URL? {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        return allowed(parent) ? parent : nil
    }

    private func allowed(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        // Go module downloads contain real manifests but are dependencies, not workspaces.
        let isGoModuleCache = zip(components, components.dropFirst()).contains { $0 == "pkg" && $1 == "mod" }
        return !isGoModuleCache && url.standardizedFileURL != home.standardizedFileURL &&
        !ProjectLocator.isAutomaticallyExcluded(url, home: home) &&
        !url.pathComponents.contains(where: Self.pruned.contains) &&
        PathSafety.isDirectory(url) &&
        (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
    }

    private func reportProject(_ url: URL, report: (ProjectSearchEvent) -> Void) throws -> Bool {
        guard allowed(url) else { return false }
        let repository = GitRepository.at(url)
        let hasMarker = repository != nil || Self.manifests.contains { name in
            let marker = url.appendingPathComponent(name)
            return !PathSafety.hasSymbolicLink(in: marker) &&
                (try? marker.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        guard hasMarker else { return false }
        report(.project(url.standardizedFileURL, worktree: repository?.isLinkedWorktree == true))
        if let repository {
            for checkout in (try? repository.registeredWorktrees()) ?? [] {
                try Task.checkCancellation()
                guard allowed(checkout), let linked = GitRepository.at(checkout),
                      linked.commonDirectory.path == repository.commonDirectory.path else { continue }
                report(.project(checkout.standardizedFileURL, worktree: linked.isLinkedWorktree))
            }
        }
        return true
    }

    private func searchFolders(report: (ProjectSearchEvent) -> Void) throws {
        let roots: [URL]
        do {
            roots = try FileManager.default.contentsOfDirectory(
                at: home, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ).filter { allowed($0) }.sorted {
                let left = Self.isContainerName($0.lastPathComponent)
                let right = Self.isContainerName($1.lastPathComponent)
                return left != right ? left : $0.path < $1.path
            }
        } catch { report(.foldersUnavailable); return }

        // Breadth first: inspect every shallow folder before exploring deeper.
        // A recognized project already covers everything below it in the real scan.
        var level = roots
        while !level.isEmpty {
            var next: [URL] = []
            for folder in level {
                try Task.checkCancellation()
                if try reportProject(folder, report: report) { continue }
                var failed = false
                guard let entries = FileManager.default.enumerator(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
                    errorHandler: { _, _ in failed = true; return true }
                ) else { report(.foldersUnavailable); continue }
                var children = Set<String>()
                var mixed = false
                while let child = entries.nextObject() as? URL {
                    try Task.checkCancellation()
                    guard !child.lastPathComponent.hasPrefix(".") else { continue }
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values?.isDirectory == true && values?.isSymbolicLink != true {
                        children.insert(child.standardizedFileURL.path)
                    } else if !["readme", "readme.md", "readme.txt", "license", "license.md", "license.txt"].contains(child.lastPathComponent.lowercased()) {
                        mixed = true
                    }
                    guard let values,
                          values.isDirectory == true, values.isSymbolicLink != true,
                          allowed(child) else { continue }
                    next.append(child)
                }
                if failed { report(.foldersUnavailable) }
                report(.container(folder, children: children, mixed: mixed || failed))
            }
            level = next
        }
    }

    private func searchIndex(report: (ProjectSearchEvent) -> Void) throws {
        do {
            var seen = Set<URL>()
            for path in try locator.indexedPaths(home) {
                try Task.checkCancellation()
                var folder = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
                // Spotlight can return .git/HEAD as well as the .git directory.
                if folder.lastPathComponent == ".git" { folder.deleteLastPathComponent() }
                guard seen.insert(folder).inserted else { continue }
                _ = try reportProject(folder, report: report)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { report(.indexUnavailable) }
    }
}

private struct CollectedProjects {
    let home: URL
    var containers: [URL: (children: Set<String>, mixed: Bool)] = [:]
    var projects = Set<URL>()
    var worktrees = Set<URL>()
    var indexUnavailable = false
    var foldersUnavailable = false

    mutating func accept(_ event: ProjectSearchEvent) {
        switch event {
        case let .project(url, worktree):
            let directory = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
            projects.insert(directory)
            if worktree { worktrees.insert(directory) }
        case let .container(url, children, mixed):
            containers[url.standardizedFileURL] = (children, mixed)
        case .refresh: break
        case .indexUnavailable: indexUnavailable = true
        case .foldersUnavailable: foldersUnavailable = true
        }
    }

    var result: ProjectSuggestionResult {
        let projectPaths = Set(projects.map(\.path))
        let workspaces = containers.compactMap { url, evidence -> URL? in
            let minimum = ProjectSuggestions.isContainerName(url.lastPathComponent) ? 1 : 2
            guard url.path != home.standardizedFileURL.path, !evidence.mixed,
                  evidence.children.count >= minimum,
                  evidence.children.isSubset(of: projectPaths) else { return nil }
            return url
        }.sorted { $0.path < $1.path }
        // Group only inspected containers whose visible contents support the inference.
        let ordered = projects.sorted { $0.pathComponents.count < $1.pathComponents.count }
        var roots: [URL] = []
        var grouped: [URL: [URL]] = [:]
        for project in ordered {
            let root = workspaces.first { PathSafety.contains(project, in: $0) } ??
                roots.first { PathSafety.contains(project, in: $0) } ?? project
            if grouped[root] == nil { roots.append(root) }
            grouped[root, default: []].append(project)
        }
        let suggestions = grouped.map { root, found in
            ProjectSuggestion(url: root, projectURLs: found.sorted { $0.path < $1.path }, worktreeURLs: found.filter(worktrees.contains))
        }.sorted { $0.url.path < $1.url.path }
        return ProjectSuggestionResult(suggestions: suggestions, indexUnavailable: indexUnavailable, foldersUnavailable: foldersUnavailable)
    }
}
