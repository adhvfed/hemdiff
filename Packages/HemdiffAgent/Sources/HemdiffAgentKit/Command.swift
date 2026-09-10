import Foundation
import HemdiffCore

public enum CommandError: Error, LocalizedError {
  case invalid(String)
  public var errorDescription: String? { if case let .invalid(message) = self { message } else { nil } }
}

public struct Command: Sendable {
  public enum Operation: Equatable, Sendable {
    case help, version, status, rootsList, rootsAdd(String), rootsRemove(String)
    case grant(String, Set<ArtifactKind>), revoke(String, Set<ArtifactKind>?)
    case inventory, plan([String]), execute(String, String), receipt(String), mcp
  }
  public let stateDirectory: URL?
  public let operation: Operation
  public static let version = "0.1.0"
  public static let supportedKinds = ArtifactKind.allCases.filter { $0 != .xcodeDerivedData }
  public static var help: String {
    """
    Hemdiff — inspect and reclaim developer build artifacts

    Usage: hemdiff [--state-directory PATH] COMMAND
      status                         Host identity, roots and permissions
      roots list                     Configured read scopes
      roots add ABSOLUTE_PATH        Add read scope (does not permit deletion)
      roots remove ROOT_ID           Remove scope and its permissions
      permissions grant ROOT_ID KIND [KIND...]
      permissions revoke ROOT_ID [KIND...]
      inventory                      Recognized artifacts in configured roots
      plan CANDIDATE_ID [ID...]       Prepare an expiring exact cleanup plan
      execute PLAN_ID --host HOST_ID  Execute under current root permissions
      receipt PLAN_ID                Retrieve the persisted cleanup outcome
      mcp                            MCP server on stdin/stdout
      --help | --version

    Kinds: \(supportedKinds.map(\.rawValue).joined(separator: ", "))

    Operations emit JSON. Root configuration is read-only until explicitly granted.
    Agent tools cannot configure roots or grant permission. --state-directory is
    for isolated tests or local administration; never accept it from tool arguments.
    Build output must be idle and unchanged for at least 30 seconds before cleanup.
    """
  }

  public init(arguments: [String]) throws {
    var args = arguments
    var state: URL?
    if args.first == "--state-directory" {
      guard args.count >= 3, args[1].hasPrefix("/"), args[1].utf8.count <= 4096 else {
        throw CommandError.invalid("--state-directory requires an absolute path and a command")
      }
      state = URL(fileURLWithPath: args[1]); args.removeFirst(2)
    }
    stateDirectory = state
    func fail() -> CommandError { .invalid("Invalid command or arguments. Run hemdiff --help.") }
    func kinds(_ values: ArraySlice<String>) throws -> Set<ArtifactKind> {
      let parsed = try values.map { value -> ArtifactKind in
        guard let kind = ArtifactKind(rawValue: value), Self.supportedKinds.contains(kind) else {
          throw CommandError.invalid("Unsupported artifact kind: \(value)")
        }
        return kind
      }
      guard Set(parsed).count == parsed.count else { throw fail() }
      return Set(parsed)
    }
    guard args.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }), args.count <= 260 else { throw fail() }
    switch args.first {
    case nil, "--help", "help": guard args.count <= 1 else { throw fail() }; operation = .help
    case "--version": guard args.count == 1 else { throw fail() }; operation = .version
    case "status": guard args.count == 1 else { throw fail() }; operation = .status
    case "inventory": guard args.count == 1 else { throw fail() }; operation = .inventory
    case "mcp": guard args.count == 1 else { throw fail() }; operation = .mcp
    case "roots":
      if args == ["roots", "list"] { operation = .rootsList }
      else if args.count == 3 && args[1] == "add" && args[2].hasPrefix("/") { operation = .rootsAdd(args[2]) }
      else if args.count == 3 && args[1] == "remove" { operation = .rootsRemove(args[2]) }
      else { throw fail() }
    case "permissions":
      guard args.count >= 3 else { throw fail() }
      if args[1] == "grant", args.count >= 4 { operation = .grant(args[2], try kinds(args.dropFirst(3))) }
      else if args[1] == "revoke" { operation = .revoke(args[2], args.count == 3 ? nil : try kinds(args.dropFirst(3))) }
      else { throw fail() }
    case "plan": guard args.count >= 2 && args.count <= 257 else { throw fail() }; operation = .plan(Array(args.dropFirst()))
    case "execute": guard args.count == 4 && args[2] == "--host" else { throw fail() }; operation = .execute(args[1], args[3])
    case "receipt": guard args.count == 2 else { throw fail() }; operation = .receipt(args[1])
    default: throw fail()
    }
  }
}

public enum JSONOutput {
  public static func data<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }
  public static func write<T: Encodable>(_ value: T) throws {
    FileHandle.standardOutput.write(try data(value) + Data([10]))
  }
}
