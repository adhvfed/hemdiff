import Darwin
import Foundation

enum ScanProcess {
    /// Drain stdout while waiting, discard stderr, and reap children on cancellation.
    /// A noisy command must never fill a pipe and stall the inventory indefinitely.
    static func output(executable: String, arguments: [String]) throws -> Data {
        try Task.checkCancellation()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        let buffer = OutputBuffer()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { reader.leave() }
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
        }
        // Wake immediately on exit; the timeout only bounds cancellation latency.
        while terminated.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
            if Task.isCancelled {
                // These are read-only system commands with no state to flush.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                reader.wait()
                throw CancellationError()
            }
        }
        process.waitUntilExit()
        reader.wait()
        try Task.checkCancellation()
        guard process.terminationStatus == 0, !buffer.overflow else { throw CocoaError(.fileReadUnknown) }
        return buffer.data
    }
}

private final class OutputBuffer: @unchecked Sendable {
    // Only the reader writes; the caller reads after joining the reader group.
    var data = Data()
    var overflow = false

    func append(_ chunk: Data) {
        guard data.count + chunk.count <= 32 * 1_024 * 1_024 else {
            overflow = true
            return
        }
        data.append(chunk)
    }
}
