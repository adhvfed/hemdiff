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
    guard let pointer = name.withCString({ hmd_read(directory.fd, $0, &count, 32_000_000) }) else {
      throw AgentServiceError.refused("State record missing, too large, or insecure: \(name)")
    }
    defer { hmd_free(pointer) }
    return try JSONDecoder().decode(T.self, from: Data(bytes: pointer, count: count))
  }
  func write<T: Encodable>(_ value: T, to name: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard data.count <= 32_000_000 else {
      throw AgentServiceError.refused(
        "Plan is too large for this service version; select fewer artifacts")
    }
    guard
      data.withUnsafeBytes({ bytes in
        name.withCString { hmd_write(directory.fd, $0, bytes.baseAddress, data.count) }
      }) == 0
    else { throw AgentServiceError.refused("Cannot durably persist state record") }
  }
  func validateID(_ id: String) throws {
    guard let parsed = UUID(uuidString: id), parsed.uuidString == id.uppercased() else {
      throw AgentServiceError.refused("Invalid identifier")
    }
  }
}
