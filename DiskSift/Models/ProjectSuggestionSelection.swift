import Foundation

/// Keep explicit choices independent of changing discovery groups.
struct ProjectSuggestionSelection {
    private(set) var selected: [URL] = []
    private var excluded: [URL] = []
    private var seenRoots = Set<String>()
    private var seenProjects = Set<String>()

    func contains(_ url: URL) -> Bool {
        selected.contains { PathSafety.contains(url, in: $0) }
    }

    mutating func update(_ suggestions: [ProjectSuggestion]) {
        for suggestion in suggestions {
            if !seenRoots.contains(suggestion.id), !contains(suggestion.url),
               !excluded.contains(where: { overlaps($0, suggestion.url) }) {
                selected.append(suggestion.url)
            } else if excluded.contains(where: { overlaps($0, suggestion.url) }) {
                for project in suggestion.projectURLs where !seenProjects.contains(project.path) {
                    if !excluded.contains(where: { overlaps($0, project) }) { selected.append(project) }
                }
            }
        }
        seenRoots.formUnion(suggestions.map(\.id))
        seenProjects.formUnion(suggestions.flatMap(\.projectURLs).map(\.path))
        selected = ArtifactScanner.normalizedRoots(selected)
    }

    mutating func set(_ url: URL, selected isSelected: Bool, suggestions: [ProjectSuggestion]) {
        if isSelected {
            selected.append(url)
            excluded.removeAll { PathSafety.contains($0, in: url) }
        } else {
            // Unchecking a child converts a whole-workspace choice into project choices.
            let covering = selected.filter { PathSafety.contains(url, in: $0) }
            selected = selected.filter { !overlaps($0, url) }
            for root in covering {
                selected += suggestions.flatMap(\.projectURLs).filter {
                    PathSafety.contains($0, in: root) && !overlaps($0, url)
                }
            }
            excluded.append(url)
        }
        selected = ArtifactScanner.normalizedRoots(selected)
    }

    private func overlaps(_ lhs: URL, _ rhs: URL) -> Bool {
        PathSafety.contains(lhs, in: rhs) || PathSafety.contains(rhs, in: lhs)
    }
}

extension ProjectSuggestion {
    static func grouping(_ suggestions: [ProjectSuggestion], under parents: [URL]) -> [ProjectSuggestion] {
        let parents = ArtifactScanner.normalizedRoots(parents)
        var grouped: [String: (url: URL, projects: [URL], worktrees: [URL])] = [:]
        for suggestion in suggestions {
            let root = parents.first { PathSafety.contains(suggestion.url, in: $0) } ?? suggestion.url
            let previous = grouped[root.path]
            grouped[root.path] = (root, (previous?.projects ?? []) + suggestion.projectURLs,
                                 (previous?.worktrees ?? []) + suggestion.worktreeURLs)
        }
        return grouped.values.map { group in
            let projects = Dictionary(group.projects.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            let worktrees = Dictionary(group.worktrees.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            return ProjectSuggestion(url: group.url, projectURLs: projects.values.sorted { $0.path < $1.path },
                                     worktreeURLs: Array(worktrees.values))
        }.sorted { $0.url.path < $1.url.path }
    }
}
