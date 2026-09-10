import Foundation
import HemdiffCore

/// A lock-backed flag can be checked from synchronous directory/process adapters.
final class CancellationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var cancelled: Bool { lock.withLock { value } }
  func cancel() { lock.withLock { value = true } }
}

/// The service is created and used on one detached worker per admitted operation.
/// No non-Sendable service instance crosses actor boundaries. Disconnect prevents
/// new work, cancels the current operation, and drains it before process exit.
public actor ServiceWorker {
  private let directory: URL
  private let session = CancellationFlag()
  private var active = false
  private var current: CancellationFlag?
  public init(directory: URL) { self.directory = directory }

  public func run<T: Sendable>(
    _ body: @escaping @Sendable (AgentArtifactService, @Sendable () -> Bool) throws -> T
  ) async throws -> T {
    guard !session.cancelled else { throw CancellationError() }
    guard !active else { throw CommandError.invalid("Hemdiff is busy; retry after the current operation finishes") }
    active = true
    let request = CancellationFlag(); current = request
    let session = self.session, directory = self.directory
    defer { active = false; current = nil }
    let task = Task.detached {
      let cancelled: @Sendable () -> Bool = { request.cancelled || session.cancelled || Task.isCancelled }
      if cancelled() { throw CancellationError() }
      let service = try AgentArtifactService(stateDirectory: directory)
      return try body(service, cancelled)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      request.cancel(); task.cancel()
    }
  }
  public func shutdown() async {
    session.cancel(); current?.cancel()
    while active { try? await Task.sleep(for: .milliseconds(20)) }
  }
}
