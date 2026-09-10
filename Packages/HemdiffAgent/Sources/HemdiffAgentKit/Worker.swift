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
  private var waiting: [UUID] = []
  private var current: CancellationFlag?
  public init(directory: URL) { self.directory = directory }

  public func run<T: Sendable>(
    _ body: @escaping @Sendable (AgentArtifactService, @Sendable () -> Bool) throws -> T
  ) async throws -> T {
    guard !session.cancelled else { throw CancellationError() }
    guard waiting.count < 8 else {
      throw CommandError.invalid(
        "Hemdiff's operation queue is full; retry after current work finishes")
    }
    let ticket = UUID()
    waiting.append(ticket)
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    do {
      while active || waiting.first != ticket {
        try Task.checkCancellation()
        guard !session.cancelled else { throw CancellationError() }
        guard ContinuousClock.now < deadline else {
          throw CommandError.invalid(
            "Timed out waiting for the current Hemdiff operation; retry later")
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      try Task.checkCancellation()
      guard !session.cancelled else { throw CancellationError() }
    } catch {
      waiting.removeAll { $0 == ticket }
      throw error
    }
    waiting.removeFirst()
    active = true
    let request = CancellationFlag()
    current = request
    let session = self.session
    let directory = self.directory
    defer {
      active = false
      current = nil
    }
    let task = Task.detached {
      let cancelled: @Sendable () -> Bool = {
        request.cancelled || session.cancelled || Task.isCancelled
      }
      if cancelled() { throw CancellationError() }
      let service = try AgentArtifactService(stateDirectory: directory)
      return try body(service, cancelled)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      request.cancel()
      task.cancel()
    }
  }
  public func shutdown() async {
    session.cancel()
    current?.cancel()
    while active || !waiting.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
  }
}
