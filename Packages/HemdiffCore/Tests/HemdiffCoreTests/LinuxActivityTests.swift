#if os(Linux)
  import Foundation
  import XCTest
  @testable import HemdiffCore

  final class LinuxActivityTests: XCTestCase {
    func testProtectedAuthenticationHelpersAndZombiesDoNotBlockUnrelatedCleanup() throws {
      for (command, processState, expected) in [
        ("(sd-pam)", "S", ActivityAssessment.State.noDetectedActivity),
        ("sshd-session", "S", .noDetectedActivity),
        ("uwsm-app", "Z", .noDetectedActivity),
        ("node", "S", .unknown),
        ("unrecognized", "S", .unknown),
      ] {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
          "hemdiff-proc-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let process = base.appendingPathComponent("42424242")
        try FileManager.default.createDirectory(at: process, withIntermediateDirectories: true)
        try Data(command.utf8).write(to: process.appendingPathComponent("comm"))
        try Data("State:\t\(processState) (fixture)\n".utf8).write(
          to: process.appendingPathComponent("status"))
        // A non-directory simulates unavailable FD enumeration even in root-run CI.
        try Data().write(to: process.appendingPathComponent("fd"))
        let assessment = try HostArtifactActivityChecker(processDirectory: base).assess(
          project: base.appendingPathComponent("project"),
          artifact: base.appendingPathComponent("project/.next"))
        XCTAssertEqual(assessment.state, expected, command)
      }
    }
  }
#endif
