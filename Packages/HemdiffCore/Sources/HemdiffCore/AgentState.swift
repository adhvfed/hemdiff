import Crypto
import Foundation
import HemdiffPOSIX

struct AgentConfiguration: Codable {
  var version = 1
  let hostID: String
  let machineBinding: String
  var roots: [AgentRoot] = []
}
final class AgentState {
  let url: URL
  let directory: DirectoryDescriptor
  init(url: URL) throws {
    guard !PathSafety.hasSymbolicLink(in: url) else {
      throw AgentServiceError.refused("State directory cannot contain symbolic links")
    }
    let canonical = PathSafety.physicalSystemPath(url)
    self.url = canonical
    let fd = canonical.path.withCString { hmd_private_directory($0) }
    guard fd >= 0 else {
      throw AgentServiceError.refused("State must be an owned private directory with mode 0700")
    }
    directory = DirectoryDescriptor(ownedFD: fd)
    try locked {
      if !exists("configuration.json") {
        try write(
          AgentConfiguration(hostID: UUID().uuidString, machineBinding: try Self.machineBinding()),
          to: "configuration.json")
      }
      _ = try configuration()
    }
  }
  private static func machineBinding() throws -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    guard hmd_machine_id(&buffer, buffer.count) == 0 else {
      throw AgentServiceError.refused("Cannot determine stable machine identity")
    }
    let value = String(cString: buffer) + ":" + String(hmd_uid())
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  func locked<T>(_ work: () throws -> T) throws -> T {
    let fd = hmd_lock(directory.fd)
    guard fd >= 0 else {
      throw AgentServiceError.refused(
        "Another Hemdiff operation is running, or its lock is insecure")
    }
    defer { _ = hmd_close(fd) }
    return try work()
  }
  func configuration() throws -> AgentConfiguration {
    let config: AgentConfiguration = try read("configuration.json")
    guard config.version == 1, UUID(uuidString: config.hostID) != nil else {
      throw AgentServiceError.refused("Unsupported or damaged state configuration")
    }
    guard config.machineBinding == (try Self.machineBinding()) else {
      throw AgentServiceError.refused(
        "State belongs to another machine or user; initialize a new state directory")
    }
    return config
  }
  func exists(_ name: String) -> Bool { name.withCString { hmd_exists(directory.fd, $0) != 0 } }
  func read<T: Decodable>(_ name: String) throws -> T {
    var count = 0
    guard let pointer = name.withCString({ hmd_read(directory.fd, $0, &count, name.hasSuffix(".plist") ? 128_000_000 : 32_000_000) }) else {
      throw AgentServiceError.refused("State record missing, too large, or insecure: \(name)")
    }
    defer { hmd_free(pointer) }
    let data = Data(bytes: pointer, count: count)
    if name.hasSuffix(".plist") { return try PropertyListDecoder().decode(T.self, from: data) }
    return try JSONDecoder().decode(T.self, from: data)
  }
  func write<T: Encodable>(_ value: T, to name: String) throws {
    let data: Data
    if name.hasSuffix(".plist") {
      let encoder = PropertyListEncoder()
      encoder.outputFormat = .binary
      data = try encoder.encode(value)
    } else {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      data = try encoder.encode(value)
    }
    guard data.count <= (name.hasSuffix(".plist") ? 128_000_000 : 32_000_000) else {
      throw AgentServiceError.refused(
        "Plan is too large for this service version; select fewer artifacts")
    }
    if name.hasSuffix(".plan.plist") {
      let manifests = try directory.names().filter { $0.hasSuffix(".plan.plist") }
      let retainedBytes = try manifests.reduce(UInt64(0)) { $0 + (try directory.stat($1).size) }
      guard manifests.count < 32, retainedBytes + UInt64(data.count) <= 256_000_000 else {
        throw AgentServiceError.refused("Pending plan storage is full; execute existing plans or let them expire")
      }
    }
    guard
      data.withUnsafeBytes({ bytes in
        name.withCString { hmd_write(directory.fd, $0, bytes.baseAddress, data.count) }
      }) == 0
    else { throw AgentServiceError.refused("Cannot durably persist state record") }
  }
  // Receipts remain small and durable; descendant manifests are disposable after completion.
  func discardManifest(_ planID: String) throws {
    for suffix in [".plan.plist", ".started.json"] {
      let name = planID + suffix
      if exists(name), name.withCString({ hmd_unlink(directory.fd, $0, 0) }) != 0 {
        throw AgentServiceError.refused("Cannot remove completed plan manifest")
      }
    }
  }
  func expirePlans(now: Date) throws {
    for name in try directory.names() where name.hasSuffix(".plan.plist") {
      let id = String(name.dropLast(".plan.plist".count))
      guard UUID(uuidString: id) != nil, !exists(id + ".started.json") else { continue }
      let stored: StoredCleanupPlan = try read(name)
      if stored.plan.expiresAt <= now { try discardManifest(id) }
    }
  }
  func validateID(_ id: String) throws {
    guard let parsed = UUID(uuidString: id), parsed.uuidString == id.uppercased() else {
      throw AgentServiceError.refused("Invalid identifier")
    }
  }
}
