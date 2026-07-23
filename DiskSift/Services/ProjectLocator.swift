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
}

struct ProjectDiscovery: Sendable {
    let markers: [ProjectMarker]
    let errorsSkipped: Int
}

struct ProjectLocator: Sendable {
    private static let query =
        #"kMDItemFSName == "Cargo.toml"c || kMDItemFSName == "package.json"c"#

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
        ".git",
        ".local",
        ".npm",
        ".orbstack",
        ".rustup",
        "Library",
        "node_modules",
        "target",
    ]

    func locate(configuration: ScanConfiguration) throws -> ProjectDiscovery {
        var markers = Set<ProjectMarker>()
        var errorsSkipped = 0

        if let automaticRoot = configuration.automaticDiscoveryRoot {
            do {
                let paths = try spotlightPaths(in: automaticRoot)
                for path in paths {
                    try Task.checkCancellation()
                    let url = URL(fileURLWithPath: path)
                    guard !Self.isAutomaticallyExcluded(url, home: automaticRoot),
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
        }

        for root in ArtifactScanner.normalizedRoots(configuration.explicitRoots) {
            try Task.checkCancellation()

            do {
                for path in try spotlightPaths(in: root) {
                    let url = URL(fileURLWithPath: path)
                    guard !Self.containsDependencyOrCacheComponent(url, relativeTo: root),
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
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.projectURL.path < $1.projectURL.path
            },
            errorsSkipped: errorsSkipped
        )
    }

    static func isAutomaticallyExcluded(_ url: URL, home: URL) -> Bool {
        let homeComponents = home.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: homeComponents) else { return true }

        let relative = Array(components.dropFirst(homeComponents.count))
        if let first = relative.first, protectedHomeFolders.contains(first) {
            return true
        }
        return relative.contains { excludedComponents.contains($0) }
    }

    private static func containsDependencyOrCacheComponent(_ url: URL, relativeTo root: URL) -> Bool {
        let rootCount = root.standardizedFileURL.pathComponents.count
        return url.standardizedFileURL.pathComponents
            .dropFirst(rootCount)
            .contains { excludedComponents.contains($0) }
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
        switch url.lastPathComponent {
        case ArtifactKind.rustTarget.markerName:
            kind = .rustTarget
        case ArtifactKind.nodeModules.markerName:
            kind = .nodeModules
        default:
            return nil
        }
        return ProjectMarker(
            projectURL: url.deletingLastPathComponent().standardizedFileURL,
            kind: kind,
            scopeRoot: scopeRoot.standardizedFileURL
        )
    }
}
