import Foundation
import HemdiffCore

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

public enum Application {
  public static func run(arguments: [String]) async -> Int32 {
    do {
      let command = try Command(arguments: arguments)
      switch command.operation {
      case .help:
        print(Command.help)
        return 0
      case .version:
        print("hemdiff \(Command.version)")
        return 0
      default: break
      }
      let worker = ServiceWorker(
        directory: command.stateDirectory ?? AgentArtifactService.defaultStateDirectory)
      if command.operation == .mcp {
        try await MCPAdapter.run(worker: worker)
        return 0
      }
      signal(SIGINT, SIG_IGN)
      signal(SIGTERM, SIG_IGN)
      let signals = [SIGINT, SIGTERM].map { number in
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { Task { await worker.shutdown() } }
        source.resume()
        return source
      }
      defer { signals.forEach { $0.cancel() } }
      let output = try await worker.run { service, cancelled -> (data: Data, code: Int32) in
        func result<T: Encodable>(_ value: T, code: Int32 = 0) throws -> (Data, Int32) {
          (try JSONOutput.data(value), code)
        }
        switch command.operation {
        case .status, .rootsList: return try result(service.status())
        case let .rootsAdd(path):
          return try result(service.configureRoot(URL(fileURLWithPath: path)))
        case let .rootsRemove(id):
          try service.removeRoot(id)
          return try result(service.status())
        case let .grant(id, kinds):
          try service.grant(rootID: id, kinds: kinds)
          return try result(service.status())
        case let .revoke(id, kinds):
          try service.revoke(rootID: id, kinds: kinds)
          return try result(service.status())
        case .inventory:
          let inventory = try service.inventory(cancelled: cancelled)
          return try result(inventory, code: inventory.cancelled ? 130 : 0)
        case let .plan(ids):
          return try result(service.prepare(candidateIDs: ids, cancelled: cancelled))
        case let .execute(id, host):
          let receipt = try service.execute(planID: id, expectedHostID: host, cancelled: cancelled)
          return try result(receipt, code: receipt.outcome == .completed ? 0 : 2)
        case let .receipt(id): return try result(service.receipt(planID: id))
        default: throw CommandError.invalid("Unsupported operation")
        }
      }
      FileHandle.standardOutput.write(output.data + Data([10]))
      await worker.shutdown()
      return output.code
    } catch {
      let message =
        error is CancellationError
        ? "Operation cancelled; retrieve the receipt if cleanup began" : error.localizedDescription
      let data =
        (try? JSONOutput.data(["error": message])) ?? Data("{\"error\":\"Hemdiff failed\"}".utf8)
      FileHandle.standardError.write(data + Data([10]))
      return error is CancellationError ? 130 : 1
    }
  }
}
