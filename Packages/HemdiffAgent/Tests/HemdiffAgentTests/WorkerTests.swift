import Foundation
import XCTest

@testable import HemdiffAgentKit

@MainActor final class WorkerTests: XCTestCase {
  func testParallelReadsQueueInsteadOfReturningBusy() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hemdiff-worker-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let worker = ServiceWorker(directory: directory)
    async let first = worker.run { service, _ in
      Thread.sleep(forTimeInterval: 0.04)
      return try service.status().hostID
    }
    async let second = worker.run { service, _ in try service.inventory().hostID }
    let hosts = try await [first, second]
    XCTAssertEqual(hosts[0], hosts[1])
    await worker.shutdown()
  }
  func testRequestCancellationReachesSynchronousWork() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hemdiff-worker-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let worker = ServiceWorker(directory: directory)
    let started = CancellationFlag()
    let work = Task {
      try await worker.run { _, cancelled in
        started.cancel()
        while !cancelled() { Thread.sleep(forTimeInterval: 0.005) }
        return "cancelled and drained"
      }
    }
    while !started.cancelled { try await Task.sleep(for: .milliseconds(5)) }
    work.cancel()
    let result = try await work.value
    XCTAssertEqual(result, "cancelled and drained")
    // Per-request cancellation must not cancel the entire session.
    let host = try await worker.run { service, _ in try service.status().hostID }
    XCTAssertFalse(host.isEmpty)
    await worker.shutdown()
  }
  func testDisconnectDrainsAndPreventsNewWork() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hemdiff-worker-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let worker = ServiceWorker(directory: directory)
    let started = CancellationFlag()
    let finished = CancellationFlag()
    let work = Task {
      try await worker.run { _, cancelled in
        started.cancel()
        while !cancelled() { Thread.sleep(forTimeInterval: 0.005) }
        Thread.sleep(forTimeInterval: 0.03)
        finished.cancel()
        return true
      }
    }
    while !started.cancelled { try await Task.sleep(for: .milliseconds(5)) }
    await worker.shutdown()
    XCTAssertTrue(finished.cancelled)
    _ = try await work.value
    do {
      _ = try await worker.run { _, _ in true }
      XCTFail("Accepted work after disconnect")
    } catch is CancellationError {}
  }
}
