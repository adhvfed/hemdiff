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
}

struct ProjectLocator: Sendable {
    private static let query =
        #"kMDItemFSName == "Cargo.toml"c || kMDItemFSName == "package.json"c || kMDItemFSName == "Package.swift"c || kMDItemFSName == "target"c || kMDItemFSName == "node_modules"c || kMDItemFSName == ".build"c"#

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

        if let automaticRoot = configuration.automaticDiscoveryRoot {
            do {
                let paths = try spotlightPaths(in: automaticRoot)
                for path in paths {
                    try Task.checkCancellation()
                    let url = URL(fileURLWithPath: path)
                    let artifactKind = Self.artifactKind(for: url)
                    guard !Self.isAutomaticallyExcluded(
                        url,
                        home: automaticRoot,
                        allowingArtifactKind: artifactKind
                    ),
                          let marker = marker(for: url, scopeRoot: automaticRoot)
                    else {
                        continue
                    }
                    markers.insert(marker)
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

            do {
                for path in try spotlightPaths(in: root) {
                    let url = URL(fileURLWithPath: path)
                    let artifactKind = Self.artifactKind(for: url)
                    guard !Self.containsDependencyOrCacheComponent(
                        url,
                        relativeTo: root,
                        allowingArtifactKind: artifactKind
                    ),
                          let marker = marker(for: url, scopeRoot: root)
                    else {
                        continue
                    }
                    markers.insert(marker)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                errorsSkipped += 1
            }

            let fallback = try walkMarkers(in: root)
            markers.formUnion(fallback.markers)
            errorsSkipped += fallback.errorsSkipped
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

    private func spotlightPaths(in root: URL) throws -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-0", "-onlyin", root.path, Self.query]
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try Task.checkCancellation()

        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileReadUnknown)
        }

        return data.split(separator: 0).compactMap {
            String(data: Data($0), encoding: .utf8)
        }
    }

    private func walkMarkers(in root: URL) throws -> ProjectDiscovery {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var markers = Set<ProjectMarker>()
        var errorsSkipped = 0

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
                    enumerator.skipDescendants()
                    continue
                }

                if values.isRegularFile == true,
                   let marker = marker(for: url, scopeRoot: root) {
                    markers.insert(marker)
                }
            } catch {
                errorsSkipped += 1
            }
        }

        return ProjectDiscovery(
            markers: Array(markers),
            errorsSkipped: errorsSkipped
        )
    }

    private func marker(for url: URL, scopeRoot: URL) -> ProjectMarker? {
        let kind: ArtifactKind
        let artifactURL: URL?
        switch url.lastPathComponent {
        case "Cargo.toml":
            kind = .rustTarget
            artifactURL = nil
        case "package.json":
            kind = .nodeModules
            artifactURL = nil
        case "Package.swift":
            kind = .swiftBuild
            artifactURL = nil
        default:
            guard let artifactKind = Self.artifactKind(for: url),
                  let markerName = artifactKind.markerName,
                  Self.isDirectoryAndNotSymbolicLink(at: url),
                  Self.isRegularFileAndNotSymbolicLink(
                      at: url.deletingLastPathComponent().appendingPathComponent(markerName)
                  )
            else {
                return nil
            }
            kind = artifactKind
            artifactURL = url.standardizedFileURL
        }

        if artifactURL == nil {
            guard Self.isRegularFileAndNotSymbolicLink(at: url) else {
                return nil
            }
        }

        return ProjectMarker(
            projectURL: url.deletingLastPathComponent().standardizedFileURL,
            kind: kind,
            scopeRoot: scopeRoot.standardizedFileURL,
            artifactURL: artifactURL
        )
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
        guard rootValues.isDirectory == true,
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
