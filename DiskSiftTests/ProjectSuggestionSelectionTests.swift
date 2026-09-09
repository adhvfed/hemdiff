import XCTest
@testable import DiskSift

final class ProjectSuggestionSelectionTests: XCTestCase {
    private let parent = URL(fileURLWithPath: "/work/AutoProjects", isDirectory: true)
    private var first: URL { parent.appendingPathComponent("first", isDirectory: true) }
    private var second: URL { parent.appendingPathComponent("second", isDirectory: true) }
    private var singles: [ProjectSuggestion] {
        [first, second].map { ProjectSuggestion(url: $0, projectURLs: [$0], worktreeURLs: []) }
    }
    private var workspace: ProjectSuggestion {
        ProjectSuggestion(url: parent, projectURLs: [first, second], worktreeURLs: [])
    }

    func testUncheckingChildSplitsWorkspaceAndSurvivesLiveUpdates() {
        var selection = ProjectSuggestionSelection()
        selection.update([workspace])
        XCTAssertEqual(selection.selected.map(\.path), [parent.path])
        selection.set(first, selected: false, suggestions: [workspace])
        XCTAssertFalse(selection.contains(parent))
        XCTAssertFalse(selection.contains(first))
        XCTAssertTrue(selection.contains(second))
        selection.update([workspace])
        XCTAssertEqual(selection.selected.map(\.path), [second.path])
    }

    func testRegroupingDoesNotRecheckExcludedProject() {
        var selection = ProjectSuggestionSelection()
        selection.update(singles)
        selection.set(first, selected: false, suggestions: singles)
        selection.update([workspace])
        XCTAssertEqual(selection.selected.map(\.path), [second.path])
        selection.set(parent, selected: true, suggestions: [workspace])
        XCTAssertEqual(selection.selected.map(\.path), [parent.path])
    }

    func testUncheckedWorkspaceStaysUncheckedAsNewProjectsArrive() {
        var selection = ProjectSuggestionSelection()
        selection.update([workspace])
        selection.set(parent, selected: false, suggestions: [workspace])
        let extra = parent.appendingPathComponent("third")
        selection.update([ProjectSuggestion(url: parent, projectURLs: [first, second, extra], worktreeURLs: [])])
        XCTAssertTrue(selection.selected.isEmpty)
    }

    func testExplicitParentChoiceGroupsSiblingsAndDeduplicatesRoots() {
        let grouped = ProjectSuggestion.grouping(singles, under: [parent])
        XCTAssertEqual(grouped.map(\.url), [parent])
        XCTAssertEqual(grouped.first?.projects, 2)
        var selection = ProjectSuggestionSelection()
        selection.update(singles)
        selection.set(parent, selected: true, suggestions: grouped)
        selection.update(grouped)
        XCTAssertEqual(selection.selected.map(\.path), [parent.path])
    }
}
