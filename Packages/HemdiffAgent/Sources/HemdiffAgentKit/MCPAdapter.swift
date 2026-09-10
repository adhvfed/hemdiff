import Foundation
import MCP

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

public enum MCPAdapter {
  static func schema(_ properties: [String: Value] = [:], required: [String] = []) -> Value {
    .object([
      "type": "object", "properties": .object(properties),
      "required": .array(required.map(Value.string)), "additionalProperties": false,
    ])
  }
  static let string: Value = .object(["type": "string", "minLength": 1, "maxLength": 4096])
  static let tools: [Tool] = [
    Tool(
      name: "status",
      description:
        "Show this host's identity, configured read scopes and locally granted cleanup permissions.",
      inputSchema: schema(), annotations: .init(readOnlyHint: true, openWorldHint: false)),
    Tool(
      name: "inventory",
      description:
        "Discover recognized build artifacts in configured roots. Optional cursor pages the same five-minute snapshot without rescanning. Omitting cursor starts a fresh scan. Estimates are not guaranteed newly available space.",
      inputSchema: schema([
        "cursor": string, "limit": .object(["type": "integer", "minimum": 1, "maximum": 200]),
      ]), annotations: .init(readOnlyHint: true, openWorldHint: false)),
    Tool(
      name: "prepare_cleanup",
      description:
        "Prepare an expiring plan for exact candidate IDs. Requires locally granted permissions; does not delete files. Busy, tracked, recently changed or unsafe output is refused. Review the returned candidates and consequences before execution.",
      inputSchema: schema(
        [
          "candidate_ids": .object([
            "type": "array", "items": string, "minItems": 1, "maxItems": 256, "uniqueItems": true,
          ])
        ], required: ["candidate_ids"]),
      annotations: .init(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)),
    Tool(
      name: "execute_cleanup",
      description:
        "Permanently remove the reviewed build artifacts in an existing plan on the expected host, under current local permissions. Revalidates before deleting. Retry returns the persisted receipt; partial/interrupted work is never silently retried.",
      inputSchema: schema(
        ["plan_id": string, "host_id": string], required: ["plan_id", "host_id"]),
      annotations: .init(
        readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)),
    Tool(
      name: "cleanup_receipt",
      description:
        "Retrieve a durable cleanup outcome, including partial/interrupted effects. Resolves a started journal as interrupted without deleting again.",
      inputSchema: schema(["plan_id": string], required: ["plan_id"]),
      annotations: .init(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)),
  ]

  public static func run(worker: ServiceWorker) async throws {
    let server = Server(
      name: "Hemdiff", version: Command.version,
      capabilities: .init(tools: .init(listChanged: false)))
    let pages = InventoryPages()
    let transport = BoundedStdio { await worker.shutdown() }
    await server.withMethodHandler(ListTools.self) { params in
      guard params.cursor == nil else { throw MCPError.invalidParams("Tool list is not paginated") }
      return .init(tools: tools)
    }
    await server.withMethodHandler(CallTool.self) { params in
      do {
        let args = try Arguments(params.arguments ?? [:], tool: params.name)
        if let token = params._meta?.progressToken {
          try await server.notify(
            ProgressNotification.message(
              .init(progressToken: token, progress: 0, total: 1, message: "Started \(params.name)"))
          )
        }
        let result: CallTool.Result
        switch params.name {
        case "status":
          result = try await response(worker.run { service, _ in try service.status() })
        case "inventory":
          let limit = try args.limit()
          if let cursor = try args.optionalString("cursor") {
            result = try await response(pages.page(cursor: cursor, limit: limit))
          } else {
            let inventory = try await worker.run { service, cancelled in
              try service.inventory(cancelled: cancelled)
            }
            result = try await response(pages.store(inventory, limit: limit))
          }
        case "prepare_cleanup":
          let ids = try args.ids()
          result = try await response(
            worker.run { service, cancelled in
              try service.prepare(candidateIDs: ids, cancelled: cancelled)
            })
        case "execute_cleanup":
          let plan = try args.string("plan_id")
          let host = try args.string("host_id")
          let receipt = try await worker.run { service, cancelled in
            try service.execute(planID: plan, expectedHostID: host, cancelled: cancelled)
          }
          result = try response(receipt, failed: receipt.outcome != .completed)
        case "cleanup_receipt":
          let plan = try args.string("plan_id")
          result = try await response(
            worker.run { service, _ in try service.receipt(planID: plan) })
        default: throw MCPError.invalidParams("Unknown tool")
        }
        if let token = params._meta?.progressToken {
          try await server.notify(
            ProgressNotification.message(
              .init(progressToken: token, progress: 1, total: 1, message: "Finished \(params.name)")
            ))
        }
        return result
      } catch let error as MCPError { throw error } catch {
        let message =
          error is CancellationError
          ? "Operation cancelled; retrieve the cleanup receipt if execution began"
          : error.localizedDescription
        return .init(
          content: [.text(message)], structuredContent: .object(["error": .string(message)]),
          isError: true)
      }
    }
    // Ignore POSIX default termination so an executing worker can journal partial
    // effects. SIGKILL/crash is recovered by the core's started-journal contract.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signals = [SIGINT, SIGTERM].map { number in
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler {
        Task {
          await transport.disconnect()
          await server.stop()
        }
      }
      source.resume()
      return source
    }
    defer { signals.forEach { $0.cancel() } }
    do {
      try await server.start(transport: transport)
      await server.waitUntilCompleted()
    } catch {
      await transport.disconnect()
      await worker.shutdown()
      throw error
    }
    await transport.disconnect()
    await worker.shutdown()
    await server.stop()
  }

  private static func response<T: Codable & Sendable>(_ value: T, failed: Bool = false) throws
    -> CallTool.Result
  {
    let data = try JSONOutput.data(value)
    // Results carry both readable text and structured JSON. Refuse while still in
    // the handler so the client receives a small tool error instead of no response.
    guard data.count <= 4 * 1024 * 1024 else {
      throw CommandError.invalid(
        "Result exceeds the MCP response limit; request a smaller inventory page or selection, or use the CLI"
      )
    }
    let structured = try JSONDecoder().decode(Value.self, from: data)
    return .init(
      content: [.text(String(decoding: data, as: UTF8.self))],
      structuredContent: Optional.some(structured), isError: failed)
  }
}

struct Arguments {
  private let values: [String: Value]
  init(_ values: [String: Value], tool: String) throws {
    let allowed: Set<String>
    switch tool {
    case "status": allowed = []
    case "inventory": allowed = ["cursor", "limit"]
    case "prepare_cleanup": allowed = ["candidate_ids"]
    case "execute_cleanup": allowed = ["plan_id", "host_id"]
    case "cleanup_receipt": allowed = ["plan_id"]
    default: throw MCPError.invalidParams("Unknown tool: \(tool)")
    }
    guard Set(values.keys).isSubset(of: allowed) else {
      throw MCPError.invalidParams("Unexpected argument")
    }
    self.values = values
  }
  func optionalString(_ key: String) throws -> String? {
    guard let value = values[key] else { return nil }
    guard case let .string(text) = value, !text.isEmpty, text.utf8.count <= 4096 else {
      throw MCPError.invalidParams("\(key) must be a nonempty string of at most 4096 bytes")
    }
    return text
  }
  func string(_ key: String) throws -> String {
    guard let value = try optionalString(key) else {
      throw MCPError.invalidParams("Missing \(key)")
    }
    return value
  }
  func limit() throws -> Int {
    guard let value = values["limit"] else { return 100 }
    guard case let .int(number) = value, (1...200).contains(number) else {
      throw MCPError.invalidParams("limit must be an integer from 1 to 200")
    }
    return number
  }
  func ids() throws -> [String] {
    guard case let .array(values) = values["candidate_ids"], (1...256).contains(values.count) else {
      throw MCPError.invalidParams("candidate_ids requires 1–256 unique IDs")
    }
    let ids = try values.map { value -> String in
      guard case let .string(id) = value, !id.isEmpty, id.utf8.count <= 4096 else {
        throw MCPError.invalidParams("Invalid candidate ID")
      }
      return id
    }
    guard Set(ids).count == ids.count else {
      throw MCPError.invalidParams("Duplicate candidate ID")
    }
    return ids
  }
}
