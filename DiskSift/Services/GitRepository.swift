import Foundation

/// Reads Git's small administrative files; never runs repository code or changes Git state.
struct GitRepository: Sendable {
    let root: URL
    let directory: URL
    let commonDirectory: URL
    let isLinkedWorktree: Bool

    static func at(_ root: URL) -> GitRepository? {
        // Directory enumerators can return /private/var while Git pointers use /var.
        // Normalize before deriving identities, independent of discovery order.
        let root = root.standardizedFileURL
        guard PathSafety.isDirectory(root) else { return nil }
        let dotGit = root.appendingPathComponent(".git")
        let directory: URL
        if PathSafety.isDirectory(dotGit) {
            directory = dotGit
        } else if let pointer = PathSafety.textFile(dotGit), pointer.hasPrefix("gitdir: ") {
            directory = resolve(String(pointer.dropFirst(8)), relativeTo: root)
        } else {
            // Bare repositories can own linked worktrees too.
            directory = root
        }
        guard PathSafety.isDirectory(directory),
              PathSafety.textFile(directory.appendingPathComponent("HEAD")) != nil else { return nil }

        if let common = PathSafety.textFile(directory.appendingPathComponent("commondir")) {
            let commonDirectory = resolve(common, relativeTo: directory)
            guard PathSafety.isDirectory(commonDirectory),
                  PathSafety.isDirectory(commonDirectory.appendingPathComponent("objects")),
                  let backlink = PathSafety.textFile(directory.appendingPathComponent("gitdir")),
                  resolve(backlink, relativeTo: directory).path == dotGit.standardizedFileURL.path else { return nil }
            return GitRepository(root: root, directory: directory, commonDirectory: commonDirectory, isLinkedWorktree: true)
        }
        guard PathSafety.isDirectory(directory.appendingPathComponent("objects")) else { return nil }
        return GitRepository(root: root, directory: directory, commonDirectory: directory, isLinkedWorktree: false)
    }

    static func enclosing(_ project: URL, stoppingAt boundary: URL) -> GitRepository? {
        var candidate = project.standardizedFileURL
        while PathSafety.contains(candidate, in: boundary) {
            if let repository = at(candidate) { return repository }
            // A submodule or invalid pointer is still a repository boundary.
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(".git").path) { return nil }
            guard candidate.path != boundary.standardizedFileURL.path, candidate.path != "/" else { break }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    func registeredWorktrees() throws -> [URL] {
        let registry = commonDirectory.appendingPathComponent("worktrees")
        var result: [URL] = []
        if commonDirectory.lastPathComponent == ".git" {
            result.append(commonDirectory.deletingLastPathComponent())
        }
        guard PathSafety.isDirectory(registry) else { return result }
        for entry in try FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil) {
            try Task.checkCancellation()
            guard PathSafety.isDirectory(entry),
                  let backlink = PathSafety.textFile(entry.appendingPathComponent("gitdir")) else { continue }
            let pointer = Self.resolve(backlink, relativeTo: entry)
            guard pointer.lastPathComponent == ".git" else { continue }
            // Validate the reverse pointer only after the caller applies scan scope policy.
            result.append(pointer.deletingLastPathComponent())
        }
        return result
    }

    private static func resolve(_ text: String, relativeTo base: URL) -> URL {
        // Git appends a line ending. Preserve spaces and embedded newlines in paths.
        var path = text
        if path.hasSuffix("\n") { path.removeLast() }
        if path.hasSuffix("\r") { path.removeLast() }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: base.path, isDirectory: true)).standardizedFileURL
    }
}
