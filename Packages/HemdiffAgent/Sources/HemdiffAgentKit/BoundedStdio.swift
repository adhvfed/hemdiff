import Foundation
import MCP
import Logging
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// MCP framing only; all JSON-RPC and MCP semantics belong to the official SDK.
/// At most sixteen 1-MiB frames are buffered. Overflow fails closed rather than
/// silently dropping requests. Polling lets EOF/signals stop a blocked reader.
actor BoundedStdio: Transport {
  nonisolated let logger = Logger(label: "hemdiff.mcp", factory: { _ in SwiftLogNoOpLogHandler() })
  private let stream: AsyncThrowingStream<Data, Swift.Error>
  private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
  private var reader: Task<Void, Never>?
  private var ended = false
  private let stopped = CancellationFlag()
  private let onEnd: @Sendable () async -> Void
  private var outputFlags: Int32?
  private var sending = false
  private var outstandingRequests: Set<ID> = []
  static let maximumFrame = 1_048_576

  init(onEnd: @escaping @Sendable () async -> Void) {
    (stream, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(16))
    self.onEnd = onEnd
  }
  func connect() async throws {
    guard reader == nil, !ended else { throw CommandError.invalid("Transport already connected") }
    signal(SIGPIPE, SIG_IGN)
    let flags = fcntl(STDOUT_FILENO, F_GETFL)
    guard flags >= 0, fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw CommandError.invalid("Cannot configure stdout")
    }
    outputFlags = flags
    let stopped = self.stopped
    reader = Task.detached { [weak self] in
      var frame = Data(), bytes = [UInt8](repeating: 0, count: 8192)
      while !stopped.cancelled && !Task.isCancelled {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 100)
        if ready < 0 {
          if errno == EINTR { continue }
          await self?.finish(CommandError.invalid("stdin read failed")); return
        }
        if ready == 0 { continue }
        let count = read(STDIN_FILENO, &bytes, bytes.count)
        if count == 0 {
          await self?.finish(frame.isEmpty ? nil : CommandError.invalid("Incomplete MCP frame at EOF")); return
        }
        if count < 0 {
          if errno == EINTR || errno == EAGAIN { continue }
          await self?.finish(CommandError.invalid("stdin read failed")); return
        }
        for byte in bytes.prefix(count) {
          if byte == 10 {
            if !frame.isEmpty {
              guard await self?.offer(frame) == true else { return }
              frame.removeAll(keepingCapacity: true)
            }
          } else {
            guard frame.count < Self.maximumFrame else {
              await self?.finish(CommandError.invalid("MCP frame exceeds 1 MiB")); return
            }
            frame.append(byte)
          }
        }
      }
    }
  }
  private func offer(_ frame: Data) async -> Bool {
    guard !ended else { return false }
    // The SDK dispatches handler Tasks independently of its stream consumer.
    // Bound requests awaiting replies too, so a client cannot move an unbounded
    // backlog from the transport into handler Tasks while stdout is stalled.
    if let json = try? JSONDecoder().decode(Value.self, from: frame) {
      guard case let .object(object) = json else {
        await finish(CommandError.invalid("MCP requires one message object per frame")); return false
      }
      if object["method"] != nil, let requestID = Self.id(object["id"]) {
        guard outstandingRequests.count < 16, !outstandingRequests.contains(requestID) else {
          await finish(CommandError.invalid("Too many outstanding requests or duplicate request ID")); return false
        }
        outstandingRequests.insert(requestID)
      } else if object["method"]?.stringValue == "notifications/cancelled",
        let parameters = object["params"]?.objectValue, let requestID = Self.id(parameters["requestId"]) {
        // Cancellation releases the client's slot; the SDK cancels the handler,
        // while ServiceWorker still admits at most one undrained filesystem job.
        outstandingRequests.remove(requestID)
      }
    }
    switch continuation.yield(frame) {
    case .enqueued: return true
    case .dropped: await finish(CommandError.invalid("MCP input queue overflow")); return false
    case .terminated: await finish(nil); return false
    @unknown default: await finish(CommandError.invalid("MCP transport closed")); return false
    }
  }
  private func finish(_ error: Swift.Error?) async {
    guard !ended else { return }
    ended = true; stopped.cancel(); reader?.cancel()
    continuation.finish(throwing: error)
    await onEnd()
  }
  func disconnect() async {
    await finish(nil)
    if let outputFlags { _ = fcntl(STDOUT_FILENO, F_SETFL, outputFlags); self.outputFlags = nil }
  }
  func receive() -> AsyncThrowingStream<Data, Swift.Error> { stream }
  func send(_ data: Data) async throws {
    // SDK handlers can send concurrently. Serialize complete frames, never bytes.
    while sending && !ended { try await Task.sleep(for: .milliseconds(5)) }
    guard !ended else { throw CancellationError() }
    guard data.count <= 16 * Self.maximumFrame else { throw CommandError.invalid("MCP response exceeds 16 MiB; select fewer candidates") }
    sending = true; defer { sending = false }
    let bytes = Array(data) + [10]
    var offset = 0
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while offset < bytes.count {
      guard !ended, !Task.isCancelled else { throw CancellationError() }
      let written = bytes.withUnsafeBytes { buffer in
        write(STDOUT_FILENO, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
      }
      if written > 0 { offset += written; continue }
      if written < 0 && errno == EINTR { continue }
      if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10)); continue
      }
      await finish(CommandError.invalid("stdout closed or stalled"))
      throw CommandError.invalid("stdout closed or stalled")
    }
    if let object = try? JSONDecoder().decode([String: Value].self, from: data),
      let requestID = Self.id(object["id"]), object["result"] != nil || object["error"] != nil {
      outstandingRequests.remove(requestID)
    }
  }
  private static func id(_ value: Value?) -> ID? {
    if case let .string(text) = value { return .string(text) }
    if case let .int(number) = value { return .number(number) }
    return nil
  }
}
