import SwiftUI

struct FindProjectsView: View {
    var finder = ProjectSuggestions()
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var result: ProjectSuggestionResult?
    @State private var checked = Set<String>()
    @State private var searchTask: Task<Void, Never>?
    @State private var stopped = false
    @State private var unchecked = Set<URL>()
    @State private var searching = true
    private var allIncluded: Bool {
        guard let result, !result.suggestions.isEmpty else { return false }
        return result.suggestions.allSatisfy(included)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Find your projects", systemImage: "magnifyingglass").font(.title2.weight(.semibold))
            Text("Select folders to add. Their files will be measured during the scan.").font(.callout).foregroundStyle(.secondary)
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
                            ForEach(result.suggestions) { suggestion in
                                Toggle(isOn: Binding(get: { included(suggestion) || checked.contains(suggestion.id) }, set: {
                                    if $0 {
                                        checked.insert(suggestion.id)
                                        unchecked = unchecked.filter { !PathSafety.contains($0, in: suggestion.url) && !PathSafety.contains(suggestion.url, in: $0) }
                                    } else {
                                        checked.remove(suggestion.id)
                                        unchecked.insert(suggestion.url)
                                    }
                                })) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(suggestion.url.path.abbreviatingHome).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                        Text("\(suggestion.projects) \(suggestion.projects == 1 ? "project" : "projects")" + (suggestion.worktrees > 0 ? " · \(suggestion.worktrees) linked worktrees" : "")).font(.caption).foregroundStyle(.secondary)
                                        if included(suggestion) {
                                            Text("Already included").font(.caption).foregroundStyle(DiskSiftTheme.node)
                                        }
                                    }
                                }.toggleStyle(.checkbox).disabled(included(suggestion))
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
                    for suggestion in result?.suggestions ?? [] where checked.contains(suggestion.id) { model.addScanRoot(suggestion.url) }
                    dismiss()
                }.buttonStyle(.borderedProminent).tint(DiskSiftTheme.node).disabled(checked.isEmpty && !allIncluded)
            }
        }.padding(24).frame(width: 520, height: 420)
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
        let existing = Set(result?.suggestions.map(\.id) ?? [])
        for suggestion in update.suggestions where !existing.contains(suggestion.id) && !included(suggestion) {
            if !unchecked.contains(where: { PathSafety.contains($0, in: suggestion.url) || PathSafety.contains(suggestion.url, in: $0) }) {
                checked.insert(suggestion.id)
            }
        }
        checked.formIntersection(Set(update.suggestions.map(\.id)))
        result = update
    }

    private func included(_ suggestion: ProjectSuggestion) -> Bool {
        model.scanRoots.contains { PathSafety.contains(suggestion.url, in: $0) }
    }

}
