import Foundation
import HemdiffPOSIX

private final class CommandCancellation {
  let check: () -> Bool
  init(_ check: @escaping () -> Bool) { self.check = check }
}

struct HostCommand {
  static func run(
    _ arguments: [String], timeout: Int32 = 10, limit: Int = 4_194_304,
    cancelled: () -> Bool = { false }
  ) throws -> (Int32, Data) {
    let strings = arguments.map { strdup($0) }
    defer { strings.forEach { free($0) } }
    var argv: [UnsafePointer<CChar>?] = strings.map { pointer in
      pointer.map { UnsafePointer<CChar>($0) }
    }
    argv.append(nil)
    var output: UnsafeMutablePointer<CChar>?
    var count = 0
    let code = withoutActuallyEscaping(cancelled) { check in
      let box = CommandCancellation(check)
      return withExtendedLifetime(box) {
        argv.withUnsafeBufferPointer {
          hmd_run(
            $0.baseAddress, &output, &count, timeout, limit,
            { context in
              guard let context else { return 0 }
              return Unmanaged<CommandCancellation>.fromOpaque(context).takeUnretainedValue()
                .check() ? 1 : 0
            }, Unmanaged.passUnretained(box).toOpaque())
        }
      }
    }
    if cancelled() {
      if let output { hmd_free(output) }
      throw CancellationError()
    }
    guard code >= 0, let output else {
      throw AgentServiceError.refused(
        "Host command unavailable, timed out, or exceeded its output limit")
    }
    defer { hmd_free(output) }
    return (code, Data(bytes: output, count: count))
  }
  static func refuseTracked(_ artifact: Artifact, cancelled: () -> Bool = { false }) throws {
    var ancestor = artifact.projectURL
    var hasRepository = false
    while ancestor.path != "/" {
      if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) {
        hasRepository = true
        break
      }
      ancestor.deleteLastPathComponent()
    }
    guard hasRepository else { return }
    let result = try run(
      [
        "/usr/bin/git", "--literal-pathspecs", "-c", "core.fsmonitor=false", "-c",
        "core.hooksPath=/dev/null", "-c", "core.untrackedCache=false", "-C", artifact.projectPath,
        "ls-files", "-z", "--", artifact.kind.folderName,
      ], cancelled: cancelled)
    guard result.0 == 0 else {
      throw AgentServiceError.refused("Git tracking status could not be established")
    }
    guard result.1.isEmpty else {
      throw AgentServiceError.refused("Build output contains Git-tracked files")
    }
  }
}

/// Best-effort host observation, combined with a quiet period and recursive revalidation.
/// This does not prove that a build cannot start after inspection.
public struct HostArtifactActivityChecker: ArtifactActivityChecking {
  private let processDirectory: URL
  public init() { processDirectory = URL(fileURLWithPath: "/proc") }
  // Injectable only inside the package for process-observation fixtures.
  init(processDirectory: URL) { self.processDirectory = processDirectory }
  public func assess(project: URL, artifact: URL) throws -> ActivityAssessment {
    try assess(project: project, artifact: artifact, cancelled: { false })
  }
  public func assess(project: URL, artifact: URL, cancelled: () -> Bool) throws
    -> ActivityAssessment
  {
    if cancelled() { throw CancellationError() }
    let project = PathSafety.physicalSystemPath(project)
    let artifact = PathSafety.physicalSystemPath(artifact)
    #if os(Linux)
      let proc = processDirectory
      guard let entries = try? FileManager.default.contentsOfDirectory(atPath: proc.path) else {
        return .init(state: .unknown, detail: "Process filesystem is unavailable")
      }
      for pid in entries where Int32(pid) != nil && Int32(pid) != hmd_pid() {
        if cancelled() { throw CancellationError() }
        let process = proc.appendingPathComponent(pid)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: process.path),
          (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == hmd_uid()
        else { continue }
        let command =
          (try? String(contentsOf: process.appendingPathComponent("comm"), encoding: .utf8))?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard
          let descriptors = try? FileManager.default.contentsOfDirectory(
            atPath: process.appendingPathComponent("fd").path)
        else {
          let status =
            (try? String(contentsOf: process.appendingPathComponent("status"), encoding: .utf8))
            ?? ""
          let state = status.split(separator: "\n").first { $0.hasPrefix("State:") }?
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().first
          // Zombies have no open descriptors. Authentication supervisors commonly
          // remain owned by this UID but deliberately deny ptrace/proc inspection.
          // Do not let those OS helpers make every unrelated workspace uncleanable.
          if state == "Z" || ["(sd-pam)", "sshd", "sshd-session"].contains(command) { continue }
          if FileManager.default.fileExists(atPath: process.path) {
            return .init(
              state: .unknown,
              detail: "Cannot inspect process \(command.isEmpty ? pid : command) owned by this user"
            )
          }
          continue
        }
        for fd in descriptors {
          if let destination = try? FileManager.default.destinationOfSymbolicLink(
            atPath: process.appendingPathComponent("fd/" + fd).path),
            contains(destination, artifact)
          {
            return .init(state: .busy, detail: "A process has build output open")
          }
        }
        if let cwd = try? FileManager.default.destinationOfSymbolicLink(
          atPath: process.appendingPathComponent("cwd").path),
          contains(cwd, artifact) || (knownBuildCommand(command) && contains(cwd, project))
        {
          return .init(state: .busy, detail: "A process is using the build directory")
        }
      }
      return .init(
        state: .noDetectedActivity,
        detail: "No open build output detected; future activity is not excluded")
    #elseif os(macOS)
      // lsof reports names only; no unrelated file contents are read or persisted.
      let result: (Int32, Data)
      do {
        result = try HostCommand.run(
          ["/usr/sbin/lsof", "-nP", "-Fpcfn", "-u", String(hmd_uid())], limit: 16_777_216,
          cancelled: cancelled)
      } catch { return .init(state: .unknown, detail: "Open-file inspection is unavailable") }
      guard result.0 == 0 else {
        return .init(state: .unknown, detail: "Open-file inspection did not complete")
      }
      var ownProcess = false
      var command = ""
      var descriptor = ""
      for line in String(decoding: result.1, as: UTF8.self).split(separator: "\n") {
        if line.first == "p" {
          ownProcess = Int32(line.dropFirst()) == hmd_pid()
          command = ""
          descriptor = ""
        }
        if line.first == "c" { command = String(line.dropFirst()) }
        if line.first == "f" { descriptor = String(line.dropFirst()) }
        if !ownProcess, line.first == "n",
          contains(String(line.dropFirst()), artifact)
            || (descriptor == "cwd" && knownBuildCommand(command)
              && contains(String(line.dropFirst()), project))
        {
          return .init(state: .busy, detail: "A process has build output open")
        }
      }
      return .init(
        state: .noDetectedActivity,
        detail: "No open build output detected; future activity is not excluded")
    #else
      return .init(state: .unknown, detail: "Activity inspection is unsupported on this platform")
    #endif
  }
  private func knownBuildCommand(_ name: String) -> Bool {
    let command = name.lowercased()
    return [
      "node", "npm", "npx", "next", "bun", "deno", "cargo", "rustc", "swift", "swiftc", "java",
      "gradle", "mvn", "python", "python3", "pytest", "ruff", "mypy", "make", "cmake", "ninja",
      "webpack", "vite",
    ].contains { command == $0 || command.hasPrefix($0 + "-") || command.hasPrefix($0 + ".") }
  }
  private func contains(_ path: String, _ root: URL) -> Bool {
    path == root.path || path.hasPrefix(root.path + "/")
  }
}
