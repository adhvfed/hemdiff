import Darwin
import Foundation

struct FileStamp: Codable, Hashable, Sendable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64

    static func capture(_ url: URL) throws -> FileStamp {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ lstat($0, &info) }) == 0 else { throw CocoaError(.fileReadNoSuchFile) }
        return FileStamp(device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                         modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
                         changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec))
    }
}

struct FileOperationResult: Sendable {
    var succeeded: [ContentItem] = []
    var failures: [String: String] = [:]
    var bytes: Int64 { succeeded.reduce(0) { $0 + $1.allocatedBytes } }
}

struct TrashSnapshot: Sendable {
    var items: [ContentItem] = []
    var roots: [URL] = []
    var unavailableRoots: [String] = []
    var errorsSkipped = 0
    var measuredAt: Date = .distantPast
    var bytes: Int64 { items.reduce(0) { $0 + $1.allocatedBytes } }
}

struct FileOperations: Sendable {
    var home = FileManager.default.homeDirectoryForCurrentUser
    // Fixtures inject a local move; production always uses macOS Trash semantics, never delete as fallback.
    var trashItem: @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func moveToTrash(_ items: [ContentItem], allowedRoots: [URL]) async -> FileOperationResult {
        await Task.detached(priority: .utility) {
            var result = FileOperationResult()
            for item in items {
                do {
                    guard allowedRoots.contains(where: { PathSafety.contains(item.url, in: $0) }),
                          !item.url.pathComponents.contains(".Trash"), !item.url.pathComponents.contains(".Trashes") else { throw CocoaError(.fileWriteNoPermission) }
                    try validate(item)
                    try trashItem(item.url)
                    result.succeeded.append(item)
                } catch { result.failures[item.path] = error.localizedDescription }
            }
            return result
        }.value
    }

    func trashRoots() -> [URL] {
        var result = [home.appendingPathComponent(".Trash")]
        for volume in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsLocalKey], options: [.skipHiddenVolumes]) ?? [] {
            guard volume.path != "/", (try? volume.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true else { continue }
            let trash = volume.appendingPathComponent(".Trashes/\(getuid())")
            if FileManager.default.fileExists(atPath: trash.path) { result.append(trash) }
        }
        return ArtifactScanner.normalizedRoots(result)
    }

    func measureTrash(roots: [URL]? = nil) async -> TrashSnapshot {
        await Task.detached(priority: .utility) {
            var snapshot = TrashSnapshot(roots: roots ?? trashRoots())
            for root in snapshot.roots {
                do {
                    guard !PathSafety.hasSymbolicLink(in: root) else { throw CocoaError(.fileReadNoPermission) }
                    let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileAllocatedSizeKey])
                    for child in children where child.lastPathComponent != ".DS_Store" {
                        do {
                            let stamp = try FileStamp.capture(child)
                            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileAllocatedSizeKey])
                            let directory = values.isDirectory == true && values.isSymbolicLink != true
                            let bytes = directory ? try ArtifactScanner.measureDirectory(child).bytes : Int64(values.fileAllocatedSize ?? 0)
                            guard try FileStamp.capture(child) == stamp else { throw CocoaError(.fileReadUnknown) }
                            snapshot.items.append(ContentItem(path: child.standardizedFileURL.path, kind: ContentKind.classify(child, isDirectory: directory), allocatedBytes: bytes, modifiedAt: values.contentModificationDate, isPackage: directory, stamp: stamp))
                        } catch { snapshot.errorsSkipped += 1 }
                    }
                } catch { snapshot.unavailableRoots.append(root.path) }
            }
            snapshot.items.sort { $0.allocatedBytes > $1.allocatedBytes }
            snapshot.measuredAt = Date()
            return snapshot
        }.value
    }

    /// Only delete the reviewed immediate children, never recursively empty a root or include new arrivals.
    func deleteFromTrash(_ items: [ContentItem], roots: [URL]) async -> FileOperationResult {
        await Task.detached(priority: .utility) {
            var result = FileOperationResult()
            for item in items {
                do {
                    guard roots.contains(where: { $0.standardizedFileURL == item.url.deletingLastPathComponent().standardizedFileURL }),
                          !PathSafety.hasSymbolicLink(in: item.url.deletingLastPathComponent()),
                          let stamp = item.stamp, try FileStamp.capture(item.url) == stamp else { throw CocoaError(.fileWriteNoPermission) }
                    try FileManager.default.removeItem(at: item.url)
                    result.succeeded.append(item)
                } catch { result.failures[item.path] = error.localizedDescription }
            }
            return result
        }.value
    }

    func validate(_ item: ContentItem) throws {
        guard !PathSafety.hasSymbolicLink(in: item.url),
              let stamp = item.stamp, try FileStamp.capture(item.url) == stamp else {
            throw NSError(domain: "DiskSift.FileOperations", code: 1, userInfo: [NSLocalizedDescriptionKey: "This item changed since the scan. Scan again before moving it."])
        }
    }
}
