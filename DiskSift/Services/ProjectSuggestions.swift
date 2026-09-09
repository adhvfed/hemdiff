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
    case project(URL, repository: Bool, worktree: Bool)
    case container(URL, children: Set<String>, readable: Bool)
    case refresh
    case indexUnavailable
    case foldersUnavailable
}

struct ProjectSuggestions: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    var locator = ProjectLocator()
    static let commonNames = ["Projects", "Developer", "Development", "Code", "src", "Source", "Repos", "Repositories"]
    static func isContainerName(_ name: String) -> Bool {
        let name = name.lowercased()
        let names = Set(commonNames.map { $0.lowercased() } + [
            "work", "workspace", "workspaces", "dev", "git", "ghq", "clones", "opensource",
            "learning", "research", "experiments", "testing", "clients", "playground", "sandbox"
        ])
        return names.contains(name) || name.hasSuffix("projects") || name.hasSuffix("research")
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
        report(.project(url.standardizedFileURL, repository: repository != nil, worktree: repository?.isLinkedWorktree == true))
        if let repository {
            for checkout in (try? repository.registeredWorktrees()) ?? [] {
                try Task.checkCancellation()
                guard allowed(checkout), let linked = GitRepository.at(checkout),
                      linked.commonDirectory.path == repository.commonDirectory.path else { continue }
                report(.project(checkout.standardizedFileURL, repository: true, worktree: linked.isLinkedWorktree))
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
                while let child = entries.nextObject() as? URL {
                    try Task.checkCancellation()
                    guard !child.lastPathComponent.hasPrefix(".") else { continue }
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values?.isDirectory == true || values?.isSymbolicLink == true {
                        children.insert(child.standardizedFileURL.path)
                    }
                    if values == nil { failed = true }
                    guard let values,
                          values.isDirectory == true, values.isSymbolicLink != true,
                          allowed(child) else { continue }
                    next.append(child)
                }
                if failed { report(.foldersUnavailable) }
                report(.container(folder, children: children, readable: !failed))
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
    var containers: [URL: (children: Set<String>, readable: Bool)] = [:]
    var projects = Set<URL>()
    var repositories = Set<URL>()
    var worktrees = Set<URL>()
    var indexUnavailable = false
    var foldersUnavailable = false

    mutating func accept(_ event: ProjectSearchEvent) {
        switch event {
        case let .project(url, repository, worktree):
            let directory = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
            projects.insert(directory)
            if repository { repositories.insert(directory) }
            if worktree { worktrees.insert(directory) }
        case let .container(url, children, readable):
            containers[url.standardizedFileURL] = (children, readable)
        case .refresh: break
        case .indexUnavailable: indexUnavailable = true
        case .foldersUnavailable: foldersUnavailable = true
        }
    }

    /// Remove nested modules without repeated URL canonicalization or pairwise scans.
    private func outermost(_ urls: Set<URL>) -> [URL] {
        let paths = Set(urls.map(\.path))
        return urls.filter { url in
            var parent = (url.path as NSString).deletingLastPathComponent
            while parent != "/" && !parent.isEmpty {
                if paths.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
    }

    var result: ProjectSuggestionResult {
        // Build ancestor evidence once per snapshot, proportional to project depth.
        // Do not compare every discovered folder with every project.
        let homePath = home.standardizedFileURL.path
        let outerProjects = outermost(projects)
        var projectsByContainer: [String: [URL]] = [:]
        var branchesByContainer: [String: Set<String>] = [:]
        var repositoriesByContainer: [String: Int] = [:]
        func ancestors(of path: String, visit: (String, String) -> Void) {
            var branch = path
            var parent = (path as NSString).deletingLastPathComponent
            while parent.hasPrefix(homePath + "/") {
                visit(parent, branch)
                branch = parent
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        for project in outerProjects {
            ancestors(of: project.path) { parent, branch in
                projectsByContainer[parent, default: []].append(project)
                branchesByContainer[parent, default: []].insert(branch)
            }
        }
        for repository in outermost(repositories) {
            ancestors(of: repository.path) { parent, _ in
                repositoriesByContainer[parent, default: 0] += 1
            }
        }
        var workspaces: [String: URL] = [:]
        for (url, evidence) in containers {
            let path = url.path
            guard evidence.readable, let found = projectsByContainer[path], !found.isEmpty else { continue }
            let branches = branchesByContainer[path, default: []].intersection(evidence.children).count
            let coverage = Double(branches) / Double(max(1, evidence.children.count))
            let isHomeChild = (path as NSString).deletingLastPathComponent == homePath
            let namedWorkspace = ProjectSuggestions.isContainerName(url.lastPathComponent)
            let repositoryCluster = repositoriesByContainer[path, default: 0] >= 2
            let mostlyProjects = coverage >= 0.5 && (isHomeChild || found.count >= 2)
            if namedWorkspace || repositoryCluster || mostlyProjects { workspaces[path] = url }
        }
        var grouped: [URL: [URL]] = [:]
        for project in outerProjects {
            var root = project
            // Ancestors are visited nearest first; the shallowest supported root wins.
            ancestors(of: project.path) { parent, _ in
                if let workspace = workspaces[parent] { root = workspace }
            }
            grouped[root, default: []].append(project)
        }
        let suggestions = grouped.map { root, found in
            ProjectSuggestion(url: root, projectURLs: found.sorted { $0.path < $1.path },
                              worktreeURLs: worktrees.filter { $0.path == root.path || $0.path.hasPrefix(root.path + "/") })
        }.sorted { $0.url.path < $1.url.path }
        return ProjectSuggestionResult(suggestions: suggestions, indexUnavailable: indexUnavailable, foldersUnavailable: foldersUnavailable)
    }
}
