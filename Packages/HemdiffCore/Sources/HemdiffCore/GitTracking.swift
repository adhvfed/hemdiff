import Foundation

#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

/// Tracking is checked against the index, including staged additions and deleted working files.
public enum GitTrackingStatus: String, Sendable, Codable {
  case tracked, untracked, unknown
}

public enum GitTracking {
  /// One bounded Git query per repository. Results are deliberately not cached across calls:
  /// a browsing hint must never authorize a later destructive operation.
  public static func statuses(
    for urls: [URL], inspectContainers: Bool = true, cancelled: () -> Bool = { false }
  ) -> [String: GitTrackingStatus] {
    var result: [String: GitTrackingStatus] = [:]
    var repositories: [String: [URL]] = [:]
    var containers: [URL] = []
    enum Discovery { case repository(URL), outside, unknown }
    var ancestors: [String: Discovery] = [:]

    func discover(_ start: URL) -> Discovery {
      var directory = start
      var visited: [String] = []
      var found: Discovery = .outside
      while true {
        if cancelled() {
          found = .unknown
          break
        }
        if let cached = ancestors[directory.path] {
          found = cached
          break
        }
        visited.append(directory.path)
        var marker = stat()
        let code = directory.appendingPathComponent(".git").withUnsafeFileSystemRepresentation { path -> Int32 in
          guard let path else { errno = EINVAL; return -1 }
          return lstat(path, &marker)
        }
        if code == 0 {
          found = .repository(directory)
          break
        }
        if errno != ENOENT {
          found = .unknown
          break
        }
        if directory.path == "/" { break }
        directory.deleteLastPathComponent()
      }
      for path in visited { ancestors[path] = found }
      return found
    }

    for original in urls {
      let url = original.standardizedFileURL
      if cancelled() {
        result[original.path] = .unknown
        continue
      }
      // Repository metadata is never an ordinary reclaimable file.
      if url.pathComponents.contains(where: { $0.lowercased() == ".git" }) {
        result[original.path] = .tracked
        continue
      }
      guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
        values.isSymbolicLink != true
      else {
        result[original.path] = .unknown
        continue
      }
      if values.isDirectory == true { containers.append(original) }
      switch discover(url.deletingLastPathComponent()) {
      case .repository(let root): repositories[root.path, default: []].append(original)
      case .outside: result[original.path] = .untracked
      case .unknown: result[original.path] = .unknown
      }
    }

    for (root, files) in repositories {
      do {
        let (code, output) = try HostCommand.run(
          [
            "/usr/bin/git", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c",
            "core.hooksPath=/dev/null", "-c", "core.untrackedCache=false", "-C", root,
            "ls-files", "--cached", "-z", "--full-name",
          ], limit: 16 * 1024 * 1024, cancelled: cancelled)
        guard code == 0 else { throw CocoaError(.fileReadUnknown) }
        let relativePaths = Dictionary(
          files.map {
            (
              $0.path,
              String($0.standardizedFileURL.path.dropFirst(root == "/" ? 1 : root.count + 1))
            )
          }, uniquingKeysWith: { first, _ in first })
        // macOS volumes are commonly case-insensitive; index casing can differ
        // after a case-only rename. Conservative folding avoids an unsafe miss.
        func key(_ path: String) -> String {
          #if os(macOS)
            return path.lowercased()
          #else
            return path
          #endif
        }
        let selected = Set(relativePaths.values.map(key))
        var tracked = Set<String>()
        for entry in output.split(separator: 0) {
          if cancelled() { throw CancellationError() }
          guard let path = String(data: Data(entry), encoding: .utf8) else {
            throw CocoaError(.fileReadUnknown)
          }
          if selected.contains(key(path)) { tracked.insert(key(path)) }
          // Keep only selected paths, so a large Git index does not inflate the status cache.
          var parent = (path as NSString).deletingLastPathComponent
          while !parent.isEmpty && parent != "." {
            if selected.contains(key(parent)) { tracked.insert(key(parent)) }
            parent = (parent as NSString).deletingLastPathComponent
          }
        }
        for file in files {
          result[file.path] =
            tracked.contains(key(relativePaths[file.path]!)) ? .tracked : .untracked
        }
      } catch {
        for file in files { result[file.path] = .unknown }
      }
    }
    for container in containers where result[container.path] == .untracked {
      guard inspectContainers else {
        result[container.path] = .unknown
        continue
      }
      // Ordinary files need no recursion. A selected package may contain a nested
      // repository: protect it, and fail closed on inaccessible or excessive traversal.
      var failed = false
      guard
        let enumerator = FileManager.default.enumerator(
          at: container,
          includingPropertiesForKeys: [.isSymbolicLinkKey], options: [],
          errorHandler: { _, _ in
            failed = true
            return false
          })
      else {
        result[container.path] = .unknown
        continue
      }
      var count = 0
      let deadline = Date().addingTimeInterval(2)
      for case let child as URL in enumerator {
        count += 1
        if cancelled() || count > 20_000 || Date() > deadline {
          failed = true
          break
        }
        if child.lastPathComponent.lowercased() == ".git" {
          result[container.path] = .tracked
          break
        }
        guard let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
          failed = true
          break
        }
        if values.isSymbolicLink == true { enumerator.skipDescendants() }
      }
      if failed { result[container.path] = .unknown }
    }
    return result
  }
}
