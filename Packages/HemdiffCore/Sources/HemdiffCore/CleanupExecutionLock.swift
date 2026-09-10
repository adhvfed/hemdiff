import Foundation
import HemdiffPOSIX

/// One mutation lease per OS user, shared by GUI and every agent state directory.
/// Preparation and inventory remain independent; the lease is released on process exit.
public enum CleanupExecutionLock {
  public static var defaultDirectory: URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    #if os(macOS)
    return home.appendingPathComponent("Library/Application Support/Hemdiff/Coordination", isDirectory: true)
    #else
    return home.appendingPathComponent(".local/state/hemdiff-coordination", isDirectory: true)
    #endif
  }

  public static func withLock<T>(at url: URL = defaultDirectory, _ work: () throws -> T) throws -> T {
    guard !PathSafety.hasSymbolicLink(in: url) else {
      throw AgentServiceError.refused("Cleanup coordination directory contains a symbolic link")
    }
    let path = PathSafety.physicalSystemPath(url).path
    let directoryFD = path.withCString { hmd_private_directory($0) }
    guard directoryFD >= 0 else {
      throw AgentServiceError.refused("Cannot open private cleanup coordination directory")
    }
    let directory = DirectoryDescriptor(ownedFD: directoryFD)
    let lockFD = hmd_lock(directory.fd)
    guard lockFD >= 0 else {
      throw AgentServiceError.refused("Another Hemdiff cleanup is running, or the coordination lock is insecure")
    }
    defer { _ = hmd_close(lockFD) }
    return try work()
  }
}
