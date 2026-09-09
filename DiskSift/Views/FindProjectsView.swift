import SwiftUI

struct FindProjectsView: View {
    var finder = ProjectSuggestions()
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var result: ProjectSuggestionResult?
    @State private var selection = ProjectSuggestionSelection()
    @State private var expanded = Set<String>()
    @State private var parentChoices: [URL] = []
    private var suggestions: [ProjectSuggestion] {
        ProjectSuggestion.grouping(result?.suggestions ?? [], under: parentChoices)
    }
    @State private var searchTask: Task<Void, Never>?
    @State private var stopped = false
    @State private var searching = true
    private var allIncluded: Bool {
        guard let result, !result.suggestions.isEmpty else { return false }
        return suggestions.allSatisfy { included($0.url) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Find your projects", systemImage: "magnifyingglass").font(.title2.weight(.semibold))
            Text("Choose workspace folders, or expand them to select individual projects.").font(.callout).foregroundStyle(.secondary)
            if searching {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Finding repositories and projects…").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop Search") {
                        stopped = true
                        searchTask?.cancel()
                    }.disabled(stopped)
                }
            }
            if let result {
                if result.suggestions.isEmpty && !searching {
                    ContentUnavailableView("No projects found", systemImage: "folder", description: Text("Choose folders manually, including locations Spotlight hasn’t indexed."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(suggestions) { suggestion in
                                suggestionRow(suggestion)
                            }
                        }.padding(16)
                    }.background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                }
                if result.indexUnavailable || result.foldersUnavailable {
                    Text(result.foldersUnavailable ? "Some folders couldn’t be read. You can add locations manually." : "Spotlight is unavailable. Folder search still works.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if stopped && !searching {
                Text("Search stopped. You can use the folders found so far.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel") { searchTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(allIncluded ? "Done" : "Use Selected Folders") {
                    searchTask?.cancel()
                    for url in selection.selected where !included(url) { model.addScanRoot(url) }
                    dismiss()
                }.buttonStyle(.borderedProminent).tint(DiskSiftTheme.node).disabled(selection.selected.isEmpty && !allIncluded)
            }
        }.padding(24).frame(width: 580, height: 480)
        .onAppear {
            searchTask = Task {
                let found = await finder.find { update in
                    await MainActor.run { apply(update) }
                }
                apply(found)
                searching = false
            }
        }
        .onDisappear { searchTask?.cancel() }
    }

    private func apply(_ update: ProjectSuggestionResult) {
        result = update
        selection.update(suggestions)
    }

    private func included(_ url: URL) -> Bool {
        model.scanRoots.contains { PathSafety.contains(url, in: $0) }
    }

    private func checked(_ url: URL) -> Binding<Bool> {
        Binding(get: { included(url) || selection.contains(url) }, set: {
            selection.set(url, selected: $0, suggestions: suggestions)
        })
    }

    private func suggestionRow(_ suggestion: ProjectSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                if suggestion.isWorkspace {
                    Button {
                        if expanded.contains(suggestion.id) { expanded.remove(suggestion.id) }
                        else { expanded.insert(suggestion.id) }
                    } label: {
                        Image(systemName: expanded.contains(suggestion.id) ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold)).frame(width: 12, height: 18)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(expanded.contains(suggestion.id) ? "Collapse" : "Expand") \(suggestion.url.lastPathComponent)")
                } else {
                    Color.clear.frame(width: 12, height: 18)
                }
                Toggle(isOn: checked(suggestion.url)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(suggestion.url.path.abbreviatingHome).font(.callout.weight(.medium))
                            .lineLimit(1).truncationMode(.middle).help(suggestion.url.path)
                        Text("\(suggestion.projects) \(suggestion.projects == 1 ? "project" : "projects")" +
                             (suggestion.worktrees > 0 ? " · \(suggestion.worktrees) linked worktrees" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                        if included(suggestion.url) {
                            Text("Already included").font(.caption).foregroundStyle(DiskSiftTheme.node)
                        } else if suggestion.isWorkspace && selection.contains(suggestion.url) {
                            Text("Includes future projects").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.toggleStyle(.checkbox).disabled(included(suggestion.url))
                Spacer(minLength: 0)
                if let parent = finder.parentOption(for: suggestion.url), !included(suggestion.url) {
                    Menu {
                        Button("Use Parent Folder: \(parent.lastPathComponent)") {
                            parentChoices = ArtifactScanner.normalizedRoots(parentChoices + [parent])
                            selection.set(parent, selected: true, suggestions: suggestions)
                            selection.update(suggestions)
                            expanded.insert(parent.path)
                        }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .help("Choose a broader scan folder")
                }
            }
            if suggestion.isWorkspace && expanded.contains(suggestion.id) {
                VStack(alignment: .leading, spacing: 10) {
                    if !included(suggestion.url) {
                        Button("Select Projects Only") {
                            selection.set(suggestion.url, selected: false, suggestions: suggestions)
                            for project in suggestion.projectURLs {
                                selection.set(project, selected: true, suggestions: suggestions)
                            }
                        }.font(.caption).buttonStyle(.link)
                    }
                    ForEach(suggestion.projectURLs, id: \.path) { project in
                        Toggle(isOn: checked(project)) {
                            Text(String(project.path.dropFirst(suggestion.url.path.count + 1)))
                                .font(.callout).lineLimit(1).truncationMode(.middle).help(project.path)
                        }.toggleStyle(.checkbox).disabled(included(project))
                    }
                }.padding(.leading, 34)
            }
        }
    }
}
