import Foundation

struct ArtifactScanner: Sendable {
    func scan(
        configuration: ScanConfiguration,
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> DiskSnapshot {
        let work = Task.detached(priority: .utility) {
            let discovery = try ProjectLocator().locate(configuration: configuration)
            return try Self.measure(
                discovery: discovery,
                configuration: configuration,
                progress: progress
            )
        }

        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    func scan(
        roots: [URL],
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async throws -> DiskSnapshot {
        try await scan(
            configuration: ScanConfiguration(
                automaticDiscoveryRoot: nil,
                explicitRoots: roots
            ),
            progress: progress
        )
    }

    static func normalizedRoots(_ roots: [URL]) -> [URL] {
        let unique = Dictionary(
            roots.map { ($0.standardizedFileURL.path, $0.standardizedFileURL) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.path.count < $1.path.count }

        var result: [URL] = []
        for candidate in unique {
            let candidatePath = candidate.path.hasSuffix("/") ? candidate.path : candidate.path + "/"
            let isNested = result.contains { root in
                let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
                return candidatePath.hasPrefix(rootPath)
            }
            if !isNested {
                result.append(candidate)
            }
        }
        return result
    }

    private static func measure(
        discovery: ProjectDiscovery,
        configuration: ScanConfiguration,
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) throws -> DiskSnapshot {
        let startedAt = Date()
        var artifacts: [Artifact] = []
        var categoryBytes: [String: Int64] = [:]
        var categoryMetadata: [String: (name: String, path: String)] = [:]
        var filesVisited = 0
        var directoriesVisited = 0
        var errorsSkipped = discovery.errorsSkipped
        var bytesMeasured: Int64 = 0
        var lastProgress = Date.distantPast
        var measuredPaths = Set<String>()

        for marker in discovery.markers {
            try Task.checkCancellation()
            let artifactURL = marker.projectURL
                .appendingPathComponent(marker.kind.folderName, isDirectory: true)
                .standardizedFileURL
            guard measuredPaths.insert(artifactURL.path).inserted else { continue }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: artifactURL.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                continue
            }

            do {
                let values = try artifactURL.resourceValues(
                    forKeys: [.isSymbolicLinkKey, .creationDateKey, .contentModificationDateKey]
                )
                guard values.isSymbolicLink != true else { continue }

                let measured = try measureDirectory(artifactURL)
                let fileIdentity = try ArtifactFileIdentity.capture(at: artifactURL)
                filesVisited += measured.files
                directoriesVisited += measured.directories
                errorsSkipped += measured.errors
                bytesMeasured += measured.bytes

                let category = categoryIdentity(
                    for: marker.projectURL,
                    root: marker.scopeRoot
                )
                categoryBytes[category.id, default: 0] += measured.bytes
                categoryMetadata[category.id] = (category.name, category.path)
                artifacts.append(
                    Artifact(
                        kind: marker.kind,
                        path: artifactURL.path,
                        projectPath: marker.projectURL.path,
                        allocatedBytes: measured.bytes,
                        createdAt: values.creationDate,
                        modifiedAt: values.contentModificationDate,
                        worktreeName: gitWorktreeName(
                            for: marker.projectURL,
                            stoppingAt: marker.scopeRoot
                        ),
                        fileIdentity: fileIdentity
                    )
                )

                if Date().timeIntervalSince(lastProgress) >= 0.25 {
                    lastProgress = Date()
                    progress(
                        ScanProgress(
                            currentPath: artifactURL.path,
                            entriesVisited: filesVisited + directoriesVisited,
                            artifactsFound: artifacts.count,
                            bytesMeasured: bytesMeasured
                        )
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                errorsSkipped += 1
            }
        }

        let categories = categoryBytes.map { key, bytes in
            let metadata = categoryMetadata[key] ?? (name: key, path: key)
            return ScannedCategory(
                id: key,
                name: metadata.name,
                path: metadata.path,
                allocatedBytes: bytes
            )
        }.sorted { $0.allocatedBytes > $1.allocatedBytes }

        let roots = (
            configuration.automaticDiscoveryRoot.map { [$0] } ?? []
        ) + normalizedRoots(configuration.explicitRoots)

        return DiskSnapshot(
            schemaVersion: DiskSnapshot.currentSchemaVersion,
            roots: roots.map(\.path),
            startedAt: startedAt,
            finishedAt: Date(),
            filesVisited: filesVisited,
            directoriesVisited: directoriesVisited,
            errorsSkipped: errorsSkipped,
            categories: categories,
            artifacts: artifacts.sorted { $0.allocatedBytes > $1.allocatedBytes }
        )
    }

    private static func gitWorktreeName(for projectURL: URL, stoppingAt root: URL) -> String? {
        var candidate = projectURL.standardizedFileURL
        let boundary = root.standardizedFileURL.path

        while candidate.path.hasPrefix(boundary) {
            let gitPointer = candidate.appendingPathComponent(".git", isDirectory: false)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: gitPointer.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return nil
                }

                if let contents = try? String(contentsOf: gitPointer, encoding: .utf8),
                   let gitDirectory = contents
                       .split(separator: "\n")
                       .first?
                       .split(separator: ":", maxSplits: 1)
                       .last?
                       .trimmingCharacters(in: .whitespacesAndNewlines),
                   !gitDirectory.isEmpty {
                    let components = URL(fileURLWithPath: gitDirectory).pathComponents
                    if let worktreesIndex = components.lastIndex(of: "worktrees"),
                       components.indices.contains(worktreesIndex + 1) {
                        return components[worktreesIndex + 1]
                    }
                }
                return candidate.lastPathComponent
            }

            guard candidate.path != boundary else { break }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return nil
    }

    private static func measureDirectory(_ url: URL) throws -> (
        bytes: Int64,
        files: Int,
        directories: Int,
        errors: Int
    ) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        process.arguments = [
            "-b",
            "-d", "throttle",
            "-c", "utility",
            "/usr/bin/du",
            "-skx",
            url.path,
        ]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return (0, 0, 1, 1)
        }

        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let kilobytesText = text.split(whereSeparator: \.isWhitespace).first,
              let kilobytes = Int64(kilobytesText)
        else {
            return (0, 0, 1, 1)
        }

        return (kilobytes * 1_024, 0, 1, 0)
    }

    private static func categoryIdentity(for url: URL, root: URL) -> (
        id: String,
        name: String,
        path: String
    ) {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        let relative = urlComponents.dropFirst(rootComponents.count)
        let first = relative.first ?? root.lastPathComponent
        let categoryURL = root.appendingPathComponent(first)
        return (categoryURL.path, first, categoryURL.path)
    }
}
