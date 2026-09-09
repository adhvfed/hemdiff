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
    var content = ContentInventory()
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

    func locate(
        configuration: ScanConfiguration,
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) throws -> ProjectDiscovery {
        var markers = Set<ProjectMarker>()
        var errorsSkipped = 0
        var repositories = Set<URL>()
        var content = ContentInventoryBuilder()

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

            // Explicit roots inside build output must not count those bytes again as personal files.
            let buildComponents: Set<String> = ["target", "node_modules", ".next", ".build", "DerivedData", ".git"]
            let classifiesContent = !root.standardizedFileURL.pathComponents.contains { buildComponents.contains($0) }
            let fallback = try walkMarkers(
                in: root, content: &content, classifiesContent: classifiesContent, progress: progress
            )
            markers.formUnion(fallback.markers)
            repositories.formUnion(fallback.repositoryRoots)
            errorsSkipped += fallback.errorsSkipped
            content.errorsSkipped += fallback.errorsSkipped
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
                    var ignoredContent = ContentInventoryBuilder()
                    let discovery = try walkMarkers(in: worktree, scopeRoot: scope, content: &ignoredContent, classifiesContent: false)
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
            errorsSkipped: errorsSkipped,
            content: content.inventory
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

    private func walkMarkers(
        in root: URL, scopeRoot: URL? = nil,
        content: inout ContentInventoryBuilder, classifiesContent: Bool = true,
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) throws -> ProjectDiscovery {
        try Task.checkCancellation()
        guard PathSafety.isDirectory(root) else { return ProjectDiscovery(markers: [], errorsSkipped: 1) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
            + (classifiesContent ? [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey] : [])
        var markers = Set<ProjectMarker>()
        var errorsSkipped = 0
        var repositories: [URL] = [root]
        if let repository = GitRepository.at(root), repository.directory.path == root.standardizedFileURL.path {
            return ProjectDiscovery(markers: [], errorsSkipped: 0, repositoryRoots: [root])
        }

        if classifiesContent {
            do {
                let values = try root.resourceValues(forKeys: Set(keys))
                if values.isPackage == true || ContentKind.classify(root, isDirectory: true) != .other {
                    try recordContent(root, values: values, content: &content)
                    return ProjectDiscovery(markers: [], errorsSkipped: 0)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { return ProjectDiscovery(markers: [], errorsSkipped: 1) }
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
        var lastProgress = Date.distantPast
        while let url = enumerator.nextObject() as? URL {
            visited += 1
            if visited % 256 == 0 {
                try Task.checkCancellation()
                if classifiesContent, Date().timeIntervalSince(lastProgress) >= 0.25 {
                    lastProgress = Date()
                    let inventory = content.inventory
                    progress(ScanProgress(
                        currentPath: url.path, entriesVisited: visited, artifactsFound: 0,
                        bytesMeasured: inventory.allocatedBytes, filesClassified: inventory.count
                    ))
                }
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

                if classifiesContent,
                   values.isRegularFile == true || values.isPackage == true
                    || (values.isDirectory == true && ContentKind.classify(url, isDirectory: true) != .other) {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    if url.lastPathComponent != ".git" {
                        do { try recordContent(url, values: values, content: &content) }
                        catch is CancellationError { throw CancellationError() }
                        catch { content.errorsSkipped += 1 }
                    }
                }

                if values.isRegularFile == true {
                    if url.lastPathComponent == ".git" || url.lastPathComponent == "HEAD" {
                        repositories.append(url.deletingLastPathComponent())
                    }
                    markers.formUnion(projectMarkers(for: url, scopeRoot: scopeRoot ?? root))
                }
            } catch is CancellationError {
                throw CancellationError()
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

    private func recordContent(
        _ url: URL, values: URLResourceValues, content: inout ContentInventoryBuilder
    ) throws {
        try Task.checkCancellation()
        let isDirectory = values.isDirectory == true
        let bytes: Int64
        if isDirectory {
            guard !PathSafety.hasSymbolicLink(in: url) else { return }
            bytes = try ArtifactScanner.measureDirectory(url).bytes
        } else {
            guard let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize, size >= 0 else {
                throw CocoaError(.fileReadUnknown)
            }
            bytes = Int64(size)
        }
        content.record(ContentItem(
            path: url.standardizedFileURL.path,
            kind: ContentKind.classify(url, isDirectory: isDirectory),
            allocatedBytes: bytes,
            modifiedAt: values.contentModificationDate,
            isPackage: isDirectory
        ))
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
