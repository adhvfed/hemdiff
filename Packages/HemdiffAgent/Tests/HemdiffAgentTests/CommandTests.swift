import XCTest
@testable import HemdiffAgentKit

final class CommandTests: XCTestCase {
  func testHelpDoesNotNeedAStateDirectory() throws {
    XCTAssertEqual(try Command(arguments: []).operation, .help)
    XCTAssertEqual(try Command(arguments: ["--version"]).operation, .version)
    XCTAssertEqual(try Command(arguments: ["--state-directory", "/unused", "--help"]).operation, .help)
  }
  func testExplicitAdministration() throws {
    XCTAssertEqual(try Command(arguments: ["roots", "add", "/projects"]).operation, .rootsAdd("/projects"))
    XCTAssertEqual(try Command(arguments: ["permissions", "grant", "root", "nextBuild"]).operation, .grant("root", [.nextBuild]))
    XCTAssertEqual(try Command(arguments: ["permissions", "revoke", "root"]).operation, .revoke("root", nil))
    XCTAssertEqual(try Command(arguments: ["execute", "plan", "--host", "host"]).operation, .execute("plan", "host"))
  }
  func testRejectAmbiguousOrUnsupportedCommands() {
    for args in [["--state-directory", "relative", "status"], ["status", "ignored"], ["roots", "add", "relative"], ["permissions", "grant", "root"], ["permissions", "grant", "root", "xcodeDerivedData"], ["permissions", "grant", "root", "nextBuild", "nextBuild"], ["execute", "plan"], ["execute", "plan", "--approved", "true"], ["plan"], ["mcp", "--root", "/"]] {
      XCTAssertThrowsError(try Command(arguments: args), "Accepted \(args)")
    }
  }
  func testToolArgumentsRejectAuthorityAndUnexpectedKeys() throws {
    XCTAssertThrowsError(try Arguments(["approved": true], tool: "execute_cleanup"))
    XCTAssertThrowsError(try Arguments(["root": "/"], tool: "inventory"))
    XCTAssertThrowsError(try Arguments([:], tool: "permissions_grant"))
    XCTAssertThrowsError(try Arguments(["limit": .double(1.5)], tool: "inventory").limit())
    XCTAssertThrowsError(try Arguments(["candidate_ids": ["a", "a"]], tool: "prepare_cleanup").ids())
    XCTAssertThrowsError(try Arguments(["cursor": .null], tool: "inventory").optionalString("cursor"))
    XCTAssertEqual(try Arguments(["limit": 200], tool: "inventory").limit(), 200)
  }
}
