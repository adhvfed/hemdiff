import Foundation

struct ScanConfiguration: Sendable {
    let automaticDiscoveryRoot: URL?
    let explicitRoots: [URL]

    static var macDefault: ScanConfiguration {
        ScanConfiguration(
            automaticDiscoveryRoot: FileManager.default.homeDirectoryForCurrentUser,
            explicitRoots: []
        )
    }
}

struct ProjectMarker: Hashable, Sendable {
    let projectURL: URL
    let kind: ArtifactKind
    let scopeRoot: URL
    let artifactURL: URL?

    init(
        projectURL: URL,
        kind: ArtifactKind,
        scopeRoot: URL,
        artifactURL: URL? = nil
    ) {
        self.projectURL = projectURL
        self.kind = kind
        self.scopeRoot = scopeRoot
        self.artifactURL = artifactURL
    }
}

struct ProjectDiscovery: Sendable {
    let markers: [ProjectMarker]
    let errorsSkipped: Int
    var repositoryRoots: [URL] = []
}

struct ProjectLocator: Sendable {
    var indexedPaths: @Sendable (URL) throws -> [String] = { try Self.spotlightPaths(in: $0) }

    private static let query =
        #"kMDItemFSName == "Cargo.toml"c || kMDItemFSName == "package.json"c || kMDItemFSName == "Package.swift"c || kMDItemFSName == "target"c || kMDItemFSName == "node_modules"c || kMDItemFSName == ".next"c || kMDItemFSName == ".build"c || kMDItemFSName == ".git"c || kMDItemFSName == "HEAD"c"#

    private static let protectedHomeFolders: Set<String> = [
        "Desktop",
        "Documents",
        "Downloads",
        "Library",
        "Movies",
        "Music",
        "Pictures",
    ]

    private static let excludedComponents: Set<String> = [
        ".Trash",
        ".cache",
        ".cargo",
        ".docker",
        ".build",
        ".git",
        ".local",
        ".npm",
        ".next",
        ".orbstack",
        ".rustup",
        "DerivedData",
        "Library",
        "node_modules",
        "target",
    ]

    static func xcodeDerivedDataRoot(in home: URL) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Developer", isDirectory: true)
            .appendingPathComponent("Xcode", isDirectory: true)
            .appendingPathComponent("DerivedData", isDirectory: true)
            .standardizedFileURL
    }

    func locate(configuration: ScanConfiguration) throws -> ProjectDiscovery {
        var markers = Set<ProjectMarker>()
        var errorsSkipped = 0
        var repositories = Set<URL>()

        if let automaticRoot = configuration.automaticDiscoveryRoot {
            do {
                let paths = try indexedPaths(automaticRoot)
                for path in paths {
                    try Task.checkCancellation()
                    let url = URL(fileURLWithPath: path)
                    let artifactKind = Self.artifactKind(for: url)
                    let isGitMarker = url.lastPathComponent == ".git" || url.lastPathComponent == "HEAD"
                    guard !Self.isAutomaticallyExcluded(
                        isGitMarker ? url.deletingLastPathComponent() : url,
                        home: automaticRoot,
                        allowingArtifactKind: artifactKind
                    )
                    else {
                        continue
                    }
                    if isGitMarker {
                        repositories.insert(url.deletingLastPathComponent())
                    } else {
                        markers.formUnion(projectMarkers(for: url, scopeRoot: automaticRoot))
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                errorsSkipped += 1
            }

            do {
                markers.formUnion(try xcodeDerivedDataMarkers(in: automaticRoot))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                errorsSkipped += 1
            }
        }

        for root in ArtifactScanner.normalizedRoots(configuration.explicitRoots) {
            try Task.checkCancellation()

            let fallback = try walkMarkers(in: root)
            markers.formUnion(fallback.markers)
            repositories.formUnion(fallback.repositoryRoots)
            errorsSkipped += fallback.errorsSkipped
        }

        for marker in markers {
            try Task.checkCancellation()
            if let repository = GitRepository.enclosing(marker.projectURL, stoppingAt: marker.scopeRoot) {
                repositories.insert(repository.root)
            }
        }
        var pending = Array(repositories)
        var visitedRepositories = Set<String>()
        var walkedWorktrees = Set<String>()
        while let root = pending.popLast() {
            try Task.checkCancellation()
            guard let repository = GitRepository.at(root),
                  visitedRepositories.insert(repository.commonDirectory.path).inserted else { continue }
            do {
                for worktree in try repository.registeredWorktrees() {
                    try Task.checkCancellation()
                    guard let scope = Self.worktreeScope(for: worktree, configuration: configuration),
                          let linked = GitRepository.at(worktree),
                          linked.commonDirectory.path == repository.commonDirectory.path else { continue }
                    guard walkedWorktrees.insert(worktree.path).inserted else { continue }
                    if configuration.explicitRoots.contains(where: {
                        PathSafety.contains(worktree, in: $0)
                            && !Self.containsDependencyOrCacheComponent(worktree, relativeTo: $0)
                    }) { continue } // Already covered by the complete explicit walk.
                    let discovery = try walkMarkers(in: worktree, scopeRoot: scope)
                    markers.formUnion(discovery.markers)
                    pending.append(contentsOf: discovery.repositoryRoots)
                    errorsSkipped += discovery.errorsSkipped
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                errorsSkipped += 1
            }
        }

        return ProjectDiscovery(
            markers: markers.sorted {
                if $0.projectURL.path == $1.projectURL.path {
                    if $0.kind == $1.kind {
                        return ($0.artifactURL?.path ?? "") < ($1.artifactURL?.path ?? "")
                    }
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.projectURL.path < $1.projectURL.path
            },
            errorsSkipped: errorsSkipped
        )
    }

    static func worktreeScope(for url: URL, configuration: ScanConfiguration) -> URL? {
        if let root = configuration.explicitRoots.first(where: { PathSafety.contains(url, in: $0) }),
           !containsDependencyOrCacheComponent(url, relativeTo: root) { return root }
        if let home = configuration.automaticDiscoveryRoot,
           url.standardizedFileURL.path != home.standardizedFileURL.path,
           !isAutomaticallyExcluded(url, home: home) { return home }
        return nil
    }

    static func isAutomaticallyExcluded(
        _ url: URL,
        home: URL,
        allowingArtifactKind: ArtifactKind? = nil
    ) -> Bool {
        let homeComponents = home.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: homeComponents) else { return true }

        let relative = Array(components.dropFirst(homeComponents.count))
        if let first = relative.first, protectedHomeFolders.contains(first) {
            return true
        }

        if let allowingArtifactKind {
            guard relative.last == allowingArtifactKind.folderName else { return true }
            return relative.dropLast().contains { excludedComponents.contains($0) }
        }

        return relative.contains { excludedComponents.contains($0) }
    }

    private static func containsDependencyOrCacheComponent(
        _ url: URL,
        relativeTo root: URL,
        allowingArtifactKind: ArtifactKind? = nil
    ) -> Bool {
        let rootCount = root.standardizedFileURL.pathComponents.count
        let relative = Array(url.standardizedFileURL.pathComponents.dropFirst(rootCount))

        if let allowingArtifactKind {
            guard relative.last == allowingArtifactKind.folderName else { return true }
            return relative.dropLast().contains { excludedComponents.contains($0) }
        }

        return relative.contains { excludedComponents.contains($0) }
    }

    private static func spotlightPaths(in root: URL) throws -> [String] {
        let data = try ScanProcess.output(executable: "/usr/bin/mdfind", arguments: ["-0", "-onlyin", root.path, Self.query])

        return data.split(separator: 0).compactMap {
            String(data: Data($0), encoding: .utf8)
        }
    }

    private func walkMarkers(in root: URL, scopeRoot: URL? = nil) throws -> ProjectDiscovery {
        try Task.checkCancellation()
        guard PathSafety.isDirectory(root) else { return ProjectDiscovery(markers: [], errorsSkipped: 1) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var markers = Set<ProjectMarker>()
        var errorsSkipped = 0
        var repositories: [URL] = [root]
        if let repository = GitRepository.at(root), repository.directory.path == root.standardizedFileURL.path {
            return ProjectDiscovery(markers: [], errorsSkipped: 0, repositoryRoots: [root])
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                errorsSkipped += 1
                return true
            }
        ) else {
            return ProjectDiscovery(markers: [], errorsSkipped: 1)
        }

        var visited = 0
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited % 256 == 0 {
                try Task.checkCancellation()
            }

            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true {
                    if values.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if values.isDirectory == true,
                   Self.excludedComponents.contains(url.lastPathComponent) {
                    if url.lastPathComponent == ".git" { repositories.append(url.deletingLastPathComponent()) }
                    enumerator.skipDescendants()
                    continue
                }

                if values.isDirectory == true,
                   FileManager.default.fileExists(atPath: url.appendingPathComponent("HEAD").path),
                   let repository = GitRepository.at(url), repository.directory.path == url.standardizedFileURL.path {
                    repositories.append(url)
                    enumerator.skipDescendants()
                    continue
                }

                if values.isRegularFile == true {
                    if url.lastPathComponent == ".git" || url.lastPathComponent == "HEAD" {
                        repositories.append(url.deletingLastPathComponent())
                    }
                    markers.formUnion(projectMarkers(for: url, scopeRoot: scopeRoot ?? root))
                }
            } catch {
                errorsSkipped += 1
            }
        }

        return ProjectDiscovery(
            markers: Array(markers),
            errorsSkipped: errorsSkipped,
            repositoryRoots: repositories
        )
    }

    private func projectMarkers(for url: URL, scopeRoot: URL) -> Set<ProjectMarker> {
        guard ["Cargo.toml", "package.json", "Package.swift"].contains(url.lastPathComponent)
                || Self.artifactKind(for: url) != nil else { return [] }
        guard PathSafety.contains(url, in: scopeRoot), !PathSafety.hasSymbolicLink(in: url) else { return [] }
        let kinds: [ArtifactKind]
        let artifactURL: URL?
        switch url.lastPathComponent {
        case "Cargo.toml":
            kinds = [.rustTarget]
            artifactURL = nil
        case "package.json":
            kinds = [.nodeModules, .nextBuild]
            artifactURL = nil
        case "Package.swift":
            kinds = [.swiftBuild]
            artifactURL = nil
        default:
            guard let artifactKind = Self.artifactKind(for: url),
                  let markerName = artifactKind.markerName,
                  Self.isDirectoryAndNotSymbolicLink(at: url),
                  Self.isRegularFileAndNotSymbolicLink(
                      at: url.deletingLastPathComponent().appendingPathComponent(markerName)
                  )
            else {
                return []
            }
            kinds = [artifactKind]
            artifactURL = url.standardizedFileURL
        }

        if artifactURL == nil {
            guard Self.isRegularFileAndNotSymbolicLink(at: url) else {
                return []
            }
        }

        return Set(kinds.map {
            ProjectMarker(
                projectURL: url.deletingLastPathComponent().standardizedFileURL,
                kind: $0,
                scopeRoot: scopeRoot.standardizedFileURL,
                artifactURL: artifactURL
            )
        })
    }

    private static func artifactKind(for url: URL) -> ArtifactKind? {
        ArtifactKind.allCases.first {
            !$0.isKnownContainerArtifact && $0.folderName == url.lastPathComponent
        }
    }

    private static func isDirectoryAndNotSymbolicLink(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        else {
            return false
        }
        return values.isSymbolicLink != true
    }

    private static func isRegularFileAndNotSymbolicLink(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func xcodeDerivedDataMarkers(in home: URL) throws -> Set<ProjectMarker> {
        let root = Self.xcodeDerivedDataRoot(in: home)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return []
        }

        let rootValues = try root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard !PathSafety.hasSymbolicLink(in: root), rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true
        else {
            return []
        }

        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var markers = Set<ProjectMarker>()
        for child in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            guard values.isDirectory == true,
                  values.isSymbolicLink != true
            else {
                continue
            }

            markers.insert(
                ProjectMarker(
                    projectURL: root,
                    kind: .xcodeDerivedData,
                    scopeRoot: home.standardizedFileURL,
                    artifactURL: child.standardizedFileURL
                )
            )
        }
        return markers
    }
}
