import Crypto
import Foundation
import HemdiffPOSIX

struct NodeStamp: Codable, Equatable, Sendable {
  let device: UInt64, mountID: UInt64, inode: UInt64, size: UInt64, blocks: UInt64
  let mtimeSeconds: Int64, mtimeNanoseconds: Int64, ctimeSeconds: Int64, ctimeNanoseconds: Int64
  let mode: UInt32, uid: UInt32, links: UInt32
  init(_ s: hmd_stat) {
    device = s.device
    mountID = s.mount_id
    inode = s.inode
    size = s.size
    blocks = s.blocks
    mode = s.mode
    uid = s.uid
    links = s.links
    mtimeSeconds = s.mtime_sec
    mtimeNanoseconds = s.mtime_nsec
    ctimeSeconds = s.ctime_sec
    ctimeNanoseconds = s.ctime_nsec
  }
  var directory: Bool { mode & 0o170000 == 0o040000 }
  var symbolicLink: Bool { mode & 0o170000 == 0o120000 }
  var regular: Bool { mode & 0o170000 == 0o100000 }
  var modified: Date {
    Date(
      timeIntervalSince1970: max(
        Double(mtimeSeconds) + Double(mtimeNanoseconds) / 1_000_000_000,
        Double(ctimeSeconds) + Double(ctimeNanoseconds) / 1_000_000_000))
  }
  func sameIdentity(_ other: NodeStamp) -> Bool {
    device == other.device && mountID == other.mountID && inode == other.inode && mode == other.mode
  }
}
struct ArtifactStamp: Codable, Equatable, Sendable {
  let project: NodeStamp
  let nodes: [String: NodeStamp]
  let markers: [String: NodeStamp]
  let markerDigests: [String: String]
  func matches(_ other: ArtifactStamp) -> Bool {
    project.sameIdentity(other.project) && nodes == other.nodes && markers == other.markers
      && markerDigests == other.markerDigests
  }
}
final class DirectoryDescriptor {
  let fd: Int32
  init(path: String) throws {
    fd = hmd_open_directory(PathSafety.physicalSystemPath(URL(fileURLWithPath: path)).path)
    if fd < 0 {
      throw AgentServiceError.refused("Cannot open directory without following links: \(path)")
    }
  }
  init(parent: DirectoryDescriptor, name: String) throws {
    fd = name.withCString { hmd_open_child(parent.fd, $0) }
    if fd < 0 { throw AgentServiceError.refused("Directory changed or is inaccessible: \(name)") }
  }
  init(ownedFD: Int32) { fd = ownedFD }
  deinit { _ = hmd_close(fd) }
  func stat() throws -> NodeStamp {
    var s = hmd_stat()
    guard hmd_stat_fd(fd, &s) == 0 else {
      throw AgentServiceError.refused("Cannot inspect directory")
    }
    return NodeStamp(s)
  }
  func stat(_ name: String) throws -> NodeStamp {
    var s = hmd_stat()
    guard name.withCString({ hmd_stat_child(fd, $0, &s) }) == 0 else {
      throw AgentServiceError.refused("Entry disappeared: \(name)")
    }
    return NodeStamp(s)
  }
  func names() throws -> [String] {
    var count = 0
    guard let pointer = hmd_names(fd, &count) else {
      throw AgentServiceError.refused("Cannot list directory")
    }
    defer { hmd_free(pointer) }
    let data = Data(bytes: pointer, count: count)
    return try data.split(separator: 0).map { bytes in
      guard let name = String(data: Data(bytes), encoding: .utf8), !name.contains("/"), name != ".",
        name != ".."
      else { throw AgentServiceError.refused("Unsupported file name encoding") }
      return name
    }.sorted()
  }
}

struct ArtifactFilesystem {
  static func canonical(_ url: URL) throws -> URL {
    guard !PathSafety.hasSymbolicLink(in: url) else {
      throw AgentServiceError.refused("Symbolic links are not allowed")
    }
    let canonical = PathSafety.physicalSystemPath(url)
    _ = try DirectoryDescriptor(path: canonical.path)
    return canonical
  }
  static func snapshot(
    _ artifact: Artifact, quietInterval: TimeInterval, now: Date, cancelled: () -> Bool, validatedKnownContainer: Bool = false
  ) throws -> ArtifactStamp {
    let project = try DirectoryDescriptor(path: artifact.projectPath)
    let root = try DirectoryDescriptor(path: artifact.path)
    let rootStat = try root.stat()
    guard rootStat.mountID == (try project.stat()).mountID else {
      throw AgentServiceError.refused("Artifact crosses a filesystem boundary")
    }
    var nodes = [String: NodeStamp]()
    func walk(_ dir: DirectoryDescriptor, _ relative: String, _ stamp: NodeStamp) throws {
      if cancelled() { throw CancellationError() }
      guard stamp.directory || stamp.regular || stamp.symbolicLink, stamp.mountID == rootStat.mountID
      else { throw AgentServiceError.refused("Mounts and special files cannot be cleaned") }
      guard now.timeIntervalSince(stamp.modified) >= quietInterval else {
        throw AgentServiceError.refused("Build output changed recently; wait for it to become idle")
      }
      nodes[relative] = stamp
      for name in try dir.names() {
        guard ![".git", ".hg", ".svn"].contains(name) else {
          throw AgentServiceError.refused("Nested version-control data cannot be cleaned")
        }
        if cancelled() { throw CancellationError() }
        let child = try dir.stat(name)
        let path = relative.isEmpty ? name : relative + "/" + name
        guard child.directory || child.regular || child.symbolicLink,
          child.mountID == rootStat.mountID
        else { throw AgentServiceError.refused("Mounts and special files cannot be cleaned") }
        if child.directory {
          let descriptor = try DirectoryDescriptor(parent: dir, name: name)
          guard try descriptor.stat() == child else {
            throw AgentServiceError.refused("Directory changed during inspection")
          }
          try walk(descriptor, path, child)
        } else {
          guard now.timeIntervalSince(child.modified) >= quietInterval else {
            throw AgentServiceError.refused(
              "Build output changed recently; wait for it to become idle")
          }
          nodes[path] = child
        }
      }
      guard try dir.stat() == stamp else {
        throw AgentServiceError.refused("Directory changed during inspection")
      }
    }
    try walk(root, "", rootStat)
    var markers = [String: NodeStamp]()
    var digests = [String: String]()
    for name in artifact.kind.markerNames {
      if let node = try? project.stat(name), node.regular {
        guard node.size <= 65_536 else {
          throw AgentServiceError.refused("Project marker exceeds bounded evidence size")
        }
        var count = 0
        guard let pointer = name.withCString({ hmd_read_evidence(project.fd, $0, &count, 65_536) })
        else { throw AgentServiceError.refused("Project marker changed during inspection") }
        let data = Data(bytes: pointer, count: count)
        hmd_free(pointer)
        guard try project.stat(name) == node else {
          throw AgentServiceError.refused("Project marker changed during inspection")
        }
        digests[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        markers[name] = node
      }
    }
    guard !markers.isEmpty || (validatedKnownContainer && artifact.kind == .xcodeDerivedData) else {
      throw AgentServiceError.refused("No bounded project marker evidence")
    }
    if artifact.kind == .terraformProviders {
      for name in try project.names()
      where ["tf", "tofu"].contains(URL(fileURLWithPath: name).pathExtension) {
        let node = try project.stat(name)
        guard node.regular else {
          throw AgentServiceError.refused("Terraform source evidence is not a regular file")
        }
        markers[name] = node
      }
    }
    return ArtifactStamp(
      project: try project.stat(), nodes: nodes, markers: markers, markerDigests: digests)
  }
  /// Rechecks every entry before unlinking it through its open parent descriptor.
  /// New/changed entries are preserved. Arbitrary hostile same-user rename races remain outside the guarantee.
  static func remove(_ artifact: Artifact, stamp: ArtifactStamp, cancelled: () -> Bool) throws
    -> Int64
  {
    let parent = try DirectoryDescriptor(path: artifact.url.deletingLastPathComponent().path)
    let name = artifact.url.lastPathComponent
    let root = try DirectoryDescriptor(parent: parent, name: name)
    guard let expected = stamp.nodes[""], try root.stat() == expected else {
      throw AgentServiceError.refused("Artifact changed before deletion")
    }
    var removed: Int64 = 0
    var remainingNodes = stamp.nodes
    // Build once: dependency trees can contain thousands of hardlinks.
    let aliasesByInode = Dictionary(grouping: stamp.nodes.filter { $0.value.regular && $0.value.links > 1 }) {
      "\($0.value.device):\($0.value.inode)"
    }.mapValues { $0.map(\.key) }
    func walk(_ directory: DirectoryDescriptor, _ relative: String) throws {
      if cancelled() { throw CancellationError() }
      for name in try directory.names() {
        if cancelled() { throw CancellationError() }
        let path = relative.isEmpty ? name : relative + "/" + name
        guard let expected = remainingNodes[path], try directory.stat(name) == expected else {
          throw AgentServiceError.refused("New or changed entry preserved: \(path)")
        }
        if expected.directory {
          let child = try DirectoryDescriptor(parent: directory, name: name)
          guard try child.stat() == expected else {
            throw AgentServiceError.refused("Directory replaced: \(path)")
          }
          try walk(child, path)
          guard try directory.stat(name).sameIdentity(expected) else {
            throw AgentServiceError.refused("Directory replaced: \(path)")
          }
        }
        var linkedFile: DirectoryDescriptor?
        if expected.regular && expected.links > 1 {
          let fd = name.withCString { hmd_open_regular(directory.fd, $0) }
          guard fd >= 0 else {
            throw AgentServiceError.refused("Cannot verify hardlinked file: \(path)")
          }
          linkedFile = DirectoryDescriptor(ownedFD: fd)
          guard try linkedFile!.stat() == expected else {
            throw AgentServiceError.refused("Hardlinked file changed: \(path)")
          }
        }
        guard name.withCString({ hmd_unlink(directory.fd, $0, expected.directory ? 1 : 0) }) == 0
        else { throw AgentServiceError.refused("Could not remove entry: \(path)") }
        if let linkedFile {
          let after = try linkedFile.stat()
          guard after.sameIdentity(expected), after.size == expected.size,
            after.mtimeSeconds == expected.mtimeSeconds,
            after.mtimeNanoseconds == expected.mtimeNanoseconds,
            after.links + 1 == expected.links
          else { throw AgentServiceError.refused("Hardlinked file changed during cleanup") }
          // Unlink changes ctime/nlink on every remaining name for this inode. Use the
          // post-unlink descriptor stamp only after verifying content metadata is unchanged.
          let aliases = aliasesByInode["\(expected.device):\(expected.inode)"] ?? []
          for key in aliases { remainingNodes[key] = after }
        }
        removed += Int64(clamping: expected.blocks) * 512
      }
    }
    try walk(root, "")
    guard try parent.stat(name).sameIdentity(expected), try root.names().isEmpty else {
      throw AgentServiceError.refused("Artifact changed during deletion")
    }
    guard name.withCString({ hmd_unlink(parent.fd, $0, 1) }) == 0 else {
      throw AgentServiceError.refused("Could not remove artifact directory")
    }
    return removed + Int64(clamping: expected.blocks) * 512
  }
}
