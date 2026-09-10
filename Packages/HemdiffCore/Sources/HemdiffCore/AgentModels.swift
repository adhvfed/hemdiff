import Foundation

public enum AgentServiceError: Error, LocalizedError, Equatable {
  case refused(String)
  public var errorDescription: String? {
    switch self {
    case let .refused(reason): return reason
    }
  }
}
public struct AgentRoot: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let path: String
  public let identity: ArtifactFileIdentity
  public var grantedKinds: Set<ArtifactKind>
}
public struct AgentStatus: Codable, Sendable {
  public let version: Int
  public let hostID: String
  public let roots: [AgentRoot]
}
public struct ArtifactCandidate: Codable, Sendable, Identifiable {
  public let id: String
  public let rootID: String
  public let artifact: Artifact
  public let evidence: [String]
  public let authorized: Bool
}
public struct ArtifactInventory: Codable, Sendable {
  public let hostID: String
  public let candidates: [ArtifactCandidate]
  public let directoriesVisited: Int
  public let errors: [String]
  public let cancelled: Bool
}
public struct CleanupPlan: Codable, Sendable, Identifiable {
  public let id: String
  public let hostID: String
  public let createdAt: Date
  public let expiresAt: Date
  public let candidates: [ArtifactCandidate]
  public let estimatedBytes: Int64
  public let quietInterval: TimeInterval
}
public struct CleanupReceipt: Codable, Sendable, Equatable {
  public enum Outcome: String, Codable, Sendable { case completed, partial, interrupted }
  public let planID: String
  public let hostID: String
  public let finishedAt: Date
  public let outcome: Outcome
  public let removedArtifactIDs: [String]
  public let estimatedRemovedBytes: Int64
  public let failures: [String: String]
  /// False means additional entries may have been removed before interruption.
  public let accountingComplete: Bool
}
public struct ActivityAssessment: Sendable {
  public enum State: String, Sendable { case noDetectedActivity, busy, unknown }
  public let state: State
  public let detail: String
  public init(state: State, detail: String) {
    self.state = state
    self.detail = detail
  }
}
public protocol ArtifactActivityChecking: Sendable {
  func assess(project: URL, artifact: URL) throws -> ActivityAssessment
  func assess(project: URL, artifact: URL, cancelled: () -> Bool) throws -> ActivityAssessment
}

struct StoredCleanupPlan: Codable {
  let plan: CleanupPlan
  let snapshots: [String: ArtifactStamp]
}

extension ArtifactActivityChecking {
  public func assess(project: URL, artifact: URL, cancelled: () -> Bool) throws
    -> ActivityAssessment
  {
    if cancelled() { throw CancellationError() }
    let result = try assess(project: project, artifact: artifact)
    if cancelled() { throw CancellationError() }
    return result
  }
}
