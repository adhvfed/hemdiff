import Foundation

/// An opaque, immutable selection captured before an interactive confirmation.
/// Only this service can construct plans; callers cannot replace their evidence.
public struct InteractiveCleanupPlan: Sendable {
  public let artifacts: [Artifact]
  public let expiresAt: Date
  public let estimatedBytes: Int64
  fileprivate let snapshots: [String: ArtifactStamp]
  fileprivate let serviceID: UUID
}

/// Uses the same no-follow inspection and deletion engine as host-local agent cleanup.
/// Interactive confirmation supplies authorization; headless grants are not consulted.
public struct InteractiveCleanup: Sendable {
  private let validator: ArtifactReclaimer
  private let activity: any ArtifactActivityChecking
  private let quietInterval: TimeInterval
  private let lifetime: TimeInterval
  private let coordinationDirectory: URL
  private let serviceID = UUID()

  public init(
    validator: ArtifactReclaimer = .init(),
    activity: any ArtifactActivityChecking = HostArtifactActivityChecker(),
    quietInterval: TimeInterval = 30, lifetime: TimeInterval = 300,
    coordinationDirectory: URL = CleanupExecutionLock.defaultDirectory
  ) {
    self.validator = validator
    self.activity = activity
    self.quietInterval = max(0, quietInterval)
    self.lifetime = max(1, lifetime)
    self.coordinationDirectory = coordinationDirectory
  }

  private func inspect(_ artifact: Artifact, cancelled: () -> Bool) throws -> ArtifactStamp {
    do {
      if cancelled() { throw CancellationError() }
      try validator.validate(artifact)
      if !artifact.kind.isKnownContainerArtifact {
        try HostCommand.refuseTracked(artifact, cancelled: cancelled)
      }
      let assessment = try activity.assess(
        project: artifact.projectURL, artifact: artifact.url, cancelled: cancelled)
      guard assessment.state == .noDetectedActivity else {
        throw AgentServiceError.refused(assessment.detail)
      }
      return try ArtifactFilesystem.snapshot(
        artifact, quietInterval: quietInterval, now: Date(),
        cancelled: cancelled, validatedKnownContainer: artifact.kind.isKnownContainerArtifact)
    } catch is CancellationError { throw CancellationError() } catch {
      throw AgentServiceError.refused("\(artifact.path): \(error.localizedDescription)")
    }
  }

  public func prepare(_ artifacts: [Artifact], cancelled: () -> Bool = { false }) throws
    -> InteractiveCleanupPlan
  {
    guard !artifacts.isEmpty, Set(artifacts.map(\.path)).count == artifacts.count else {
      throw AgentServiceError.refused("Select distinct build folders")
    }
    for artifact in artifacts {
      guard
        !artifacts.contains(where: {
          $0.id != artifact.id && PathSafety.contains(artifact.url, in: $0.url)
        })
      else {
        throw AgentServiceError.refused("Select parent or nested build folders, not both")
      }
    }
    var snapshots: [String: ArtifactStamp] = [:]
    var owners: [String: String] = [:]
    for artifact in artifacts {
      let stamp = try inspect(artifact, cancelled: cancelled)
      for node in stamp.nodes.values where node.regular && node.links > 1 {
        let key = "\(node.device):\(node.inode)"
        if let owner = owners[key], owner != artifact.id {
          throw AgentServiceError.refused(
            "Selected folders share hardlinks; clean them one at a time")
        }
        owners[key] = artifact.id
      }
      snapshots[artifact.id] = stamp
    }
    let bytes = snapshots.values.reduce(Int64(0)) { total, snapshot in
      snapshot.nodes.values.reduce(total) { $0 + Int64(clamping: $1.blocks) * 512 }
    }
    return .init(
      artifacts: artifacts, expiresAt: Date().addingTimeInterval(lifetime),
      estimatedBytes: bytes, snapshots: snapshots, serviceID: serviceID)
  }

  public func execute(_ plan: InteractiveCleanupPlan, cancelled: () -> Bool = { false })
    -> ReclaimResult
  {
    var removed = Set<String>()
    var bytes: Int64 = 0
    var failures: [String: String] = [:]
    do {
      try CleanupExecutionLock.withLock(at: coordinationDirectory) {
        guard plan.serviceID == serviceID, Date() < plan.expiresAt else {
          throw AgentServiceError.refused("Cleanup review expired. Review the folders again.")
        }
        // Preflight the entire reviewed selection before the first mutation.
        for artifact in plan.artifacts {
          guard
            try plan.snapshots[artifact.id]?.matches(inspect(artifact, cancelled: cancelled))
              == true
          else {
            throw AgentServiceError.refused(
              "Build output changed after review. Review the folders again.")
          }
        }
        for artifact in plan.artifacts {
          guard Date() < plan.expiresAt else {
            throw AgentServiceError.refused(
              "Cleanup review expired. Review remaining folders again.")
          }
          guard let expected = plan.snapshots[artifact.id],
            try expected.matches(inspect(artifact, cancelled: cancelled))
          else {
            throw AgentServiceError.refused(
              "Build output changed after review. Remaining folders were preserved.")
          }
          guard Date() < plan.expiresAt else {
            throw AgentServiceError.refused(
              "Cleanup review expired during inspection. Review the folders again.")
          }
          bytes += try ArtifactFilesystem.remove(artifact, stamp: expected, cancelled: cancelled)
          removed.insert(artifact.id)
        }
      }
    } catch {
      // A concurrent write or cancellation can leave an artifact partially removed.
      // Count only completed folders; never claim the whole selection was reclaimed.
      for artifact in plan.artifacts where !removed.contains(artifact.id) {
        failures[artifact.id] =
          error is CancellationError
          ? "Cleanup cancelled. Some entries may already have been removed. Scan again."
          : error.localizedDescription
      }
    }
    return .init(reclaimedIDs: removed, reclaimedBytes: bytes, failures: failures)
  }
}
