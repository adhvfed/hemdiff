import AppKit
import SwiftUI

struct SetupWizard: View {
    var finder = ProjectSuggestions()
    @EnvironmentObject private var model: AppModel
    @State private var result: ProjectSuggestionResult?
    @State private var selection = ProjectSuggestionSelection()
    @State private var manualRoots: [URL] = []
    @State private var searching = true
    @State private var searchTask: Task<Void, Never>?

    private var suggestions: [ProjectSuggestion] {
        var found = ProjectSuggestion.grouping(result?.suggestions ?? [], under: manualRoots)
        for root in manualRoots where !found.contains(where: { PathSafety.contains(root, in: $0.url) }) {
            found.append(ProjectSuggestion(url: root, projectURLs: [], worktreeURLs: []))
        }
        return found.sorted { $0.url.path < $1.url.path }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image("BrandMark").resizable().scaledToFit().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Choose folders to scan").font(.system(size: 28, weight: .semibold, design: .rounded)).tracking(-0.6)
                }
            }
            HStack {
                if searching {
                    ProgressView().controlSize(.small)
                    Text("Finding your workspaces…")
                    Spacer()
                    Button("Stop Search") { searchTask?.cancel() }
                } else {
                    Label(suggestions.isEmpty ? "Choose a folder to get started" : "\(suggestions.count) folders found",
                          systemImage: suggestions.isEmpty ? "folder.badge.plus" : "checkmark.circle.fill")
                        .foregroundStyle(DiskSiftTheme.node)
                    Spacer()
                }
            }.font(.callout)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(suggestions) { suggestion in
                        Toggle(isOn: Binding(get: { selection.contains(suggestion.url) }, set: {
                            selection.set(suggestion.url, selected: $0, suggestions: suggestions)
                        })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(suggestion.url.path.abbreviatingHome).font(.callout.weight(.medium))
                                    .lineLimit(1).truncationMode(.middle).help(suggestion.url.path)
                                if suggestion.projects > 0 {
                                    Text("\(suggestion.projects) \(suggestion.projects == 1 ? "project" : "projects")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.toggleStyle(.checkbox)
                    }
                    if !searching && suggestions.isEmpty {
                        Text("Choose the folder where you keep your projects. You can add more later.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            HStack {
                Button("Choose Folders…") { chooseFolders() }
                Spacer()
            }
            if result?.foldersUnavailable == true || result?.indexUnavailable == true {
                Text("Some locations couldn’t be checked. You can add them manually.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Label("Nothing is deleted without your confirmation.", systemImage: "checkmark.shield")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("Set Up Later") {
                    searchTask?.cancel()
                    model.finishSetup(startScan: false)
                }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(selection.selected.isEmpty ? "Select a Folder" : "Scan \(selection.selected.count) \(selection.selected.count == 1 ? "Folder" : "Folders")") {
                    searchTask?.cancel()
                    model.completeSetup(scanRoots: selection.selected)
                }
                .buttonStyle(HemdiffButtonStyle(emphasis: .primary)).tint(DiskSiftTheme.node)
                .keyboardShortcut(.defaultAction).disabled(selection.selected.isEmpty)
            }
        }
        .padding(28).frame(width: 580, height: 520).buttonStyle(HemdiffButtonStyle())
        .background {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [DiskSiftTheme.node.opacity(0.06), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .onAppear {
            manualRoots = model.scanRoots
            selection.update(suggestions)
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

    private func apply(_ result: ProjectSuggestionResult) {
        self.result = result
        selection.update(suggestions)
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folders"
        if panel.runModal() == .OK {
            manualRoots = ArtifactScanner.normalizedRoots(manualRoots + panel.urls)
            for root in panel.urls { selection.set(root, selected: true, suggestions: suggestions) }
            selection.update(suggestions)
        }
    }
}
