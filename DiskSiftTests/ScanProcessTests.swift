import Foundation
import XCTest
@testable import DiskSift

final class ScanProcessTests: XCTestCase {
    func testDrainsOutputLargerThanPipeCapacity() throws {
        let data = try ScanProcess.output(executable: "/usr/bin/seq", arguments: ["1", "50000"])
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasSuffix("50000\n"))
        XCTAssertGreaterThan(data.count, 65_536)
    }

    func testNonzeroExitThrows() {
        XCTAssertThrowsError(try ScanProcess.output(executable: "/usr/bin/false", arguments: []))
    }

    func testCancellationStopsRunningChildPromptly() async throws {
        let started = Date()
        let task = Task.detached { try ScanProcess.output(executable: "/bin/sleep", arguments: ["30"]) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
