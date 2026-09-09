import SwiftUI

struct FindProjectsView: View {
    var finder = ProjectSuggestions()
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var result: ProjectSuggestionResult?
    @State private var checked = Set<String>()
    @State private var error: String?
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
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Checking project folders, Spotlight, and Git worktrees…").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView("Search stopped", systemImage: "clock", description: Text(error))
            } else if let result {
                if result.suggestions.isEmpty {
                    ContentUnavailableView("No projects found", systemImage: "folder", description: Text("Choose folders manually, including locations Spotlight hasn’t indexed."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(result.suggestions) { suggestion in
                                Toggle(isOn: Binding(get: { included(suggestion) || checked.contains(suggestion.id) }, set: {
                                    if $0 { checked.insert(suggestion.id) } else { checked.remove(suggestion.id) }
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
                if result.limited || result.indexUnavailable {
                    Text(result.limited ? "Search limit reached. These are partial results; you can add more folders manually." : "Spotlight was unavailable. Suggestions come from common project folders.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button(searching ? "Cancel Search" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(allIncluded ? "Done" : "Use Selected Folders") {
                    for suggestion in result?.suggestions ?? [] where checked.contains(suggestion.id) { model.addScanRoot(suggestion.url) }
                    dismiss()
                }.buttonStyle(.borderedProminent).tint(DiskSiftTheme.node).disabled(searching || (checked.isEmpty && !allIncluded))
            }
        }.padding(24).frame(width: 520, height: 420)
        .task {
            do {
                let found = try await finder.find()
                guard !Task.isCancelled else { return }
                result = found
                checked = Set(found.suggestions.filter { !included($0) }.map(\.id))
            } catch {
                if !Task.isCancelled { self.error = "The search could not finish within its time limit. You can still choose folders manually." }
            }
            searching = false
        }
    }
    private func included(_ suggestion: ProjectSuggestion) -> Bool {
        model.scanRoots.contains { PathSafety.contains(suggestion.url, in: $0) }
    }

}
