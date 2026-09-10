import Foundation

/// Host-local artifact service. Root and permission administration belong to the local CLI,
/// never to an agent-controlled tool. All execution is serialized and journaled.
public final class AgentArtifactService {
  private let state: AgentState
  private let activity: any ArtifactActivityChecking
  private let quietInterval: TimeInterval
  private let planLifetime: TimeInterval
  public init(
    stateDirectory: URL,
    activityChecker: any ArtifactActivityChecking = HostArtifactActivityChecker(),
    quietInterval: TimeInterval = 30, planLifetime: TimeInterval = 300
  ) throws {
    guard quietInterval >= 0, planLifetime > 0, planLifetime <= 3600 else {
      throw AgentServiceError.refused("Invalid cleanup timing policy")
    }
    state = try AgentState(url: stateDirectory)
    activity = activityChecker
    self.quietInterval = quietInterval
    self.planLifetime = planLifetime
  }
  public static var defaultStateDirectory: URL {
    #if os(macOS)
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/HemdiffAgent", isDirectory: true)
    #else
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".local/state/hemdiff", isDirectory: true)
    #endif
  }
  public func status() throws -> AgentStatus {
    try state.locked {
      let config = try state.configuration()
      return AgentStatus(version: config.version, hostID: config.hostID, roots: config.roots)
    }
  }
  /// Read access only. Mutation requires a separate explicit grant.
  @discardableResult public func configureRoot(_ url: URL) throws -> AgentRoot {
    try state.locked {
      let canonical = try ArtifactFilesystem.canonical(url)
      guard canonical.path != "/", !PathSafety.contains(stateURL, in: canonical) else {
        throw AgentServiceError.refused(
          "A scan root cannot contain agent state or be the filesystem root")
      }
      var config = try state.configuration()
      if let existing = config.roots.first(where: { $0.path == canonical.path }) { return existing }
      guard
        !config.roots.contains(where: {
          PathSafety.contains(canonical, in: URL(fileURLWithPath: $0.path))
            || PathSafety.contains(URL(fileURLWithPath: $0.path), in: canonical)
        })
      else { throw AgentServiceError.refused("Configured roots cannot overlap") }
      let root = AgentRoot(
        id: UUID().uuidString, path: canonical.path,
        identity: try ArtifactFileIdentity.capture(at: canonical), grantedKinds: [])
      config.roots.append(root)
      try state.write(config, to: "configuration.json")
      return root
    }
  }
  // Read back the descriptor path only for root-state overlap validation; injected state URL is retained below.
  private var stateURL: URL { state.url }
  public func grant(rootID: String, kinds: Set<ArtifactKind>) throws {
    try changeGrant(rootID: rootID) { $0.formUnion(kinds) }
  }
  public func revoke(rootID: String, kinds: Set<ArtifactKind>? = nil) throws {
    try changeGrant(rootID: rootID) { if let kinds { $0.subtract(kinds) } else { $0.removeAll() } }
  }
  public func removeRoot(_ rootID: String) throws {
    try state.locked {
      var config = try state.configuration()
      guard config.roots.contains(where: { $0.id == rootID }) else {
        throw AgentServiceError.refused("Unknown root")
      }
      config.roots.removeAll { $0.id == rootID }
      try state.write(config, to: "configuration.json")
    }
  }
  private func changeGrant(rootID: String, _ update: (inout Set<ArtifactKind>) -> Void) throws {
    try state.locked {
      var config = try state.configuration()
      guard let index = config.roots.firstIndex(where: { $0.id == rootID }) else {
        throw AgentServiceError.refused("Unknown root")
      }
      update(&config.roots[index].grantedKinds)
      try state.write(config, to: "configuration.json")
    }
  }
  public func inventory(cancelled: () -> Bool = { false }) throws -> ArtifactInventory {
    let config = try state.locked { try state.configuration() }
    return try inventory(config: config, cancelled: cancelled)
  }
  private func inventory(config: AgentConfiguration, cancelled: () -> Bool) throws
    -> ArtifactInventory
  {
    var candidates: [ArtifactCandidate] = []
    var errors: [String] = []
    var visited = 0
    let pruned = Self.prunedDirectories
    func visit(_ url: URL, root: AgentRoot, mountID: UInt64) throws {
      if cancelled() { throw CancellationError() }
      let directory = try DirectoryDescriptor(path: url.path)
      guard try directory.stat().mountID == mountID else {
        throw AgentServiceError.refused("Mount boundary skipped: \(url.path)")
      }
      visited += 1
      let names = try directory.names()
      let nameSet = Set(names)
      var artifactFirstComponents = Set<String>()
      for kind in ArtifactKind.allCases
      where !kind.isKnownContainerArtifact
        && nameSet.contains(String(kind.folderName.split(separator: "/")[0]))
        && !nameSet.isDisjoint(with: kind.markerNames)
        && ArtifactRules.matches(kind, project: url) {
        let output = url.appendingPathComponent(kind.folderName, isDirectory: true)
        guard PathSafety.isDirectory(output) else { continue }
        do {
          let identity = try ArtifactFileIdentity.capture(at: output)
          let artifact = Artifact(
            kind: kind, path: output.path, projectPath: url.path, allocatedBytes: 0, createdAt: nil,
            modifiedAt: nil, fileIdentity: identity)
          let stamp = try ArtifactFilesystem.snapshot(
            artifact, quietInterval: 0, now: Date(), cancelled: cancelled)
          let bytes = stamp.nodes.values.reduce(Int64(0)) { $0 + Int64(clamping: $1.blocks) * 512 }
          let measured = Artifact(
            kind: kind, path: output.path, projectPath: url.path, allocatedBytes: bytes,
            createdAt: nil, modifiedAt: stamp.nodes[""]?.modified, fileIdentity: identity)
          candidates.append(
            ArtifactCandidate(
              id: measured.id, rootID: root.id, artifact: measured,
              evidence: stamp.markers.keys.sorted(), authorized: root.grantedKinds.contains(kind)))
          artifactFirstComponents.insert(String(kind.folderName.split(separator: "/")[0]))
        } catch is CancellationError { throw CancellationError() } catch {
          errors.append("\(output.path): \(error.localizedDescription)")
        }
      }
      for name in names
      where !pruned.contains(name) && !artifactFirstComponents.contains(name) {
        if cancelled() { throw CancellationError() }
        let child = try directory.stat(name)
        if child.directory {
          do {
            try visit(
              url.appendingPathComponent(name, isDirectory: true), root: root, mountID: mountID)
          } catch is CancellationError { throw CancellationError() } catch {
            errors.append(error.localizedDescription)
          }
        }
      }
    }
    var wasCancelled = false
    for root in config.roots {
      do {
        guard try ArtifactFileIdentity.capture(at: URL(fileURLWithPath: root.path)) == root.identity
        else {
          throw AgentServiceError.refused("Configured root changed; reconfigure it before scanning")
        }
        let descriptor = try DirectoryDescriptor(path: root.path)
        try visit(URL(fileURLWithPath: root.path), root: root, mountID: descriptor.stat().mountID)
      } catch is CancellationError {
        wasCancelled = true
        break
      } catch { errors.append(error.localizedDescription) }
    }
    return ArtifactInventory(
      hostID: config.hostID,
      candidates: candidates.sorted { $0.artifact.allocatedBytes > $1.artifact.allocatedBytes },
      directoriesVisited: visited, errors: errors, cancelled: wasCancelled)
  }
  public func prepare(candidateIDs: [String], cancelled: () -> Bool = { false }) throws
    -> CleanupPlan
  {
    try state.locked {
      guard !candidateIDs.isEmpty, Set(candidateIDs).count == candidateIDs.count else {
        throw AgentServiceError.refused("Select distinct artifact IDs")
      }
      let config = try state.configuration()
      try state.expirePlans(now: Date())
      let selected = try candidateIDs.map { try resolveCandidate($0, configuration: config, cancelled: cancelled) }
      guard Set(selected.map { $0.artifact.path }).count == selected.count else {
        throw AgentServiceError.refused("Select each artifact path once")
      }
      var snapshots: [String: ArtifactStamp] = [:]
      for candidate in selected {
        try authorize(candidate, configuration: config)
        try checkActivity(candidate.artifact, cancelled: cancelled)
        try HostCommand.refuseTracked(candidate.artifact, cancelled: cancelled)
        snapshots[candidate.id] = try ArtifactFilesystem.snapshot(
          candidate.artifact, quietInterval: quietInterval, now: Date(), cancelled: cancelled)
      }
      // Hardlink metadata changes across artifacts during unlink. Keep those operations
      // separate so every artifact is fully revalidated before any mutation begins.
      var ownersByInode: [String: String] = [:]
      for (candidateID, snapshot) in snapshots {
        for node in snapshot.nodes.values where node.regular && node.links > 1 {
          let inode = "\(node.device):\(node.inode)"
          if let owner = ownersByInode[inode], owner != candidateID {
            throw AgentServiceError.refused("Selected artifacts share hardlinks; prepare and clean them one at a time")
          }
          ownersByInode[inode] = candidateID
        }
      }
      let now = Date()
      let plan = CleanupPlan(
        id: UUID().uuidString, hostID: config.hostID, createdAt: now,
        expiresAt: now.addingTimeInterval(planLifetime), candidates: selected,
        estimatedBytes: selected.reduce(0) { $0 + $1.artifact.allocatedBytes },
        quietInterval: quietInterval)
      try state.write(
        StoredCleanupPlan(plan: plan, snapshots: snapshots), to: plan.id + ".plan.plist")
      return plan
    }
  }
  public func execute(planID: String, expectedHostID: String, cancelled: () -> Bool = { false })
    throws -> CleanupReceipt
  {
    try state.validateID(planID)
    return try CleanupExecutionLock.withLock {
      try state.locked {
      let config = try state.configuration()
      guard expectedHostID == config.hostID else {
        throw AgentServiceError.refused("Plan belongs to another host")
      }
      if state.exists(planID + ".receipt.json") { return try state.read(planID + ".receipt.json") }
      let stored: StoredCleanupPlan = try state.read(planID + ".plan.plist")
      let plan = stored.plan
      guard plan.hostID == config.hostID, plan.id == planID else {
        throw AgentServiceError.refused("Plan identity mismatch")
      }
      if state.exists(planID + ".started.json") {
        return try interruptedReceipt(planID: planID, hostID: config.hostID)
      }
      guard plan.expiresAt > Date() else { throw AgentServiceError.refused("Cleanup plan expired") }
      func revalidate(_ candidate: ArtifactCandidate) throws -> ArtifactStamp {
        if cancelled() { throw CancellationError() }
        try authorize(candidate, configuration: config)
        try ArtifactReclaimer().validate(candidate.artifact)
        try HostCommand.refuseTracked(candidate.artifact, cancelled: cancelled)
        try checkActivity(candidate.artifact, cancelled: cancelled)
        guard let stamp = stored.snapshots[candidate.id] else {
          throw AgentServiceError.refused("Plan has no snapshot")
        }
        let current = try ArtifactFilesystem.snapshot(
          candidate.artifact, quietInterval: max(quietInterval, plan.quietInterval), now: Date(),
          cancelled: cancelled)
        guard current.matches(stamp) else {
          throw AgentServiceError.refused("Artifact or project evidence changed since planning")
        }
        return stamp
      }
      for candidate in plan.candidates { _ = try revalidate(candidate) }
      try state.write(["planID": planID, "hostID": config.hostID], to: planID + ".started.json")
      var removed: [String] = []
      var failures: [String: String] = [:]
      var bytes: Int64 = 0
      for candidate in plan.candidates {
        do {
          if cancelled() { throw CancellationError() }
          let stamp = try revalidate(candidate)
          _ = try ArtifactFilesystem.remove(candidate.artifact, stamp: stamp, cancelled: cancelled)
          removed.append(candidate.id)
          bytes += candidate.artifact.allocatedBytes
        } catch {
          failures[candidate.id] = "Cleanup may be partial: " + error.localizedDescription
          break
        }
      }
      let receipt = CleanupReceipt(
        planID: planID, hostID: config.hostID, finishedAt: Date(),
        outcome: failures.isEmpty ? .completed : .partial, removedArtifactIDs: removed,
        estimatedRemovedBytes: bytes, failures: failures, accountingComplete: failures.isEmpty)
      try state.write(receipt, to: planID + ".receipt.json")
      if receipt.outcome == .completed { try? state.discardManifest(planID) }
      return receipt
      }
    }
  }
  public func receipt(planID: String) throws -> CleanupReceipt {
    try state.validateID(planID)
    return try state.locked {
      if state.exists(planID + ".receipt.json") { return try state.read(planID + ".receipt.json") }
      let config = try state.configuration()
      let stored: StoredCleanupPlan = try state.read(planID + ".plan.plist")
      guard stored.plan.id == planID, stored.plan.hostID == config.hostID,
        state.exists(planID + ".started.json") else {
        throw AgentServiceError.refused("No execution receipt exists for this plan")
      }
      return try interruptedReceipt(planID: planID, hostID: config.hostID)
    }
  }
  private func interruptedReceipt(planID: String, hostID: String) throws -> CleanupReceipt {
    let receipt = CleanupReceipt(planID: planID, hostID: hostID, finishedAt: Date(),
      outcome: .interrupted, removedArtifactIDs: [], estimatedRemovedBytes: 0,
      failures: ["execution": "Previous execution was interrupted; inspect and prepare a new plan. No deletion was retried."],
      accountingComplete: false)
    try state.write(receipt, to: planID + ".receipt.json")
    return receipt
  }
  private static let prunedDirectories: Set<String> = [
    ".git", "node_modules", "target", ".next", ".build", ".terraform", ".turbo", ".venv", "venv",
    ".pytest_cache", ".ruff_cache", ".mypy_cache",
  ]

  // IDs are selectors, never authority. Resolve only an exact rule-derived path inside
  // a configured root, then perform the same evidence and traversal checks as inventory.
  private func resolveCandidate(_ id: String, configuration: AgentConfiguration,
                                cancelled: () -> Bool) throws -> ArtifactCandidate {
    if cancelled() { throw CancellationError() }
    let parts = id.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, let kind = ArtifactKind(rawValue: String(parts[0])),
      !kind.isKnownContainerArtifact, parts[1].hasPrefix("/") else {
      throw AgentServiceError.refused("Invalid artifact ID")
    }
    let selectedURL = URL(fileURLWithPath: String(parts[1])).standardizedFileURL
    guard selectedURL.path == String(parts[1]) else { throw AgentServiceError.refused("Noncanonical artifact path") }
    let output = PathSafety.physicalSystemPath(selectedURL)
    var project = output
    for _ in kind.folderName.split(separator: "/") { project.deleteLastPathComponent() }
    guard project.appendingPathComponent(kind.folderName).path == output.path,
      let root = configuration.roots.first(where: { PathSafety.contains(project, in: URL(fileURLWithPath: $0.path)) }),
      try ArtifactFileIdentity.capture(at: URL(fileURLWithPath: root.path)) == root.identity else {
      throw AgentServiceError.refused("Artifact is outside configured roots or its root changed")
    }
    let rootDescriptor = try DirectoryDescriptor(path: root.path)
    let mount = try rootDescriptor.stat().mountID
    var cursor = project
    while cursor.path != root.path {
      if cancelled() { throw CancellationError() }
      guard !Self.prunedDirectories.contains(cursor.lastPathComponent),
        try DirectoryDescriptor(path: cursor.path).stat().mountID == mount else {
        throw AgentServiceError.refused("Artifact is nested in an excluded directory or another mount")
      }
      let parent = cursor.deletingLastPathComponent()
      for ancestorKind in ArtifactKind.allCases where !ancestorKind.isKnownContainerArtifact {
        let ancestorOutput = parent.appendingPathComponent(ancestorKind.folderName)
        if PathSafety.contains(project, in: ancestorOutput), ArtifactRules.matches(ancestorKind, project: parent) {
          throw AgentServiceError.refused("Select the enclosing artifact instead")
        }
      }
      cursor = parent
    }
    let identity = try ArtifactFileIdentity.capture(at: output)
    let artifact = Artifact(kind: kind, path: output.path, projectPath: project.path,
      allocatedBytes: 0, createdAt: nil, modifiedAt: nil, fileIdentity: identity)
    try ArtifactReclaimer().validate(artifact)
    let stamp = try ArtifactFilesystem.snapshot(artifact, quietInterval: 0, now: Date(), cancelled: cancelled)
    let measured = Artifact(kind: kind, path: output.path, projectPath: project.path,
      allocatedBytes: stamp.nodes.values.reduce(0) { $0 + Int64(clamping: $1.blocks) * 512 },
      createdAt: nil, modifiedAt: stamp.nodes[""]?.modified, fileIdentity: identity)
    return ArtifactCandidate(id: measured.id, rootID: root.id, artifact: measured,
      evidence: stamp.markers.keys.sorted(), authorized: root.grantedKinds.contains(kind))
  }

  private func authorize(_ candidate: ArtifactCandidate, configuration: AgentConfiguration) throws {
    guard let root = configuration.roots.first(where: { $0.id == candidate.rootID }),
      root.grantedKinds.contains(candidate.artifact.kind),
      (try? ArtifactFileIdentity.capture(at: URL(fileURLWithPath: root.path))) == root.identity,
      PathSafety.contains(candidate.artifact.projectURL, in: URL(fileURLWithPath: root.path)),
      !candidate.artifact.kind.isKnownContainerArtifact
    else { throw AgentServiceError.refused("No current cleanup permission for this artifact") }
  }
  private func checkActivity(_ artifact: Artifact, cancelled: () -> Bool) throws {
    let assessment = try activity.assess(
      project: artifact.projectURL, artifact: artifact.url, cancelled: cancelled)
    guard assessment.state == .noDetectedActivity else {
      throw AgentServiceError.refused(assessment.detail)
    }
  }
}
