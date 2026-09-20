import AppKit
import XCTest
@testable import DiskSift

@MainActor
final class MainWindowTests: XCTestCase {
    private var opened: [NSWindow] = []

    override func tearDown() {
        for window in opened { window.close() }
        opened = []
        super.tearDown()
    }

    /// canBecomeMain needs an on-screen titled window.
    private func openWindow(title: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = title
        window.orderFront(nil)
        opened.append(window)
        return window
    }

    func testTheMainSceneIsFoundWhileItShowsADestinationTitle() {
        let scene = openWindow(title: "Files")
        let other = openWindow(title: "Hemdiff")
        MainWindow.track(scene)
        XCTAssertIdentical(MainWindow.existing(among: [other, scene]), scene)
    }

    func testAnUntrackedWindowIsNeverTakenForTheMainScene() {
        let other = openWindow(title: "Hemdiff")
        XCTAssertNil(MainWindow.existing(among: [other]))
    }
}
