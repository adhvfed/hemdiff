import Combine
import Foundation

@MainActor
final class FileReviewModel: ObservableObject {
    @Published var kinds = Set<ContentKind>()
    @Published var search = ""
    @Published var order: FileOrder = .size
    @Published private(set) var items: [ContentItem] = []
    @Published private(set) var checked: [String: ContentItem] = [:]
    @Published private(set) var count = 0
    @Published private(set) var offset = 0
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published var focused = Set<String>()
    @Published private(set) var protection: [String: FileGitStatus] = [:]
    private let protectionCheck: @Sendable ([ContentItem]) async -> [String: FileGitStatus]
    init(protectionCheck: @escaping @Sendable ([ContentItem]) async -> [String: FileGitStatus] = { await FileGitProtection().statuses(for: $0) }) {
        self.protectionCheck = protectionCheck
    }
    private var generation = UUID()
    private var inspectionTokens: [String: UUID] = [:]
    let pageSize = 250
    var checkedBytes: Int64 { checked.values.reduce(0) { $0 + $1.allocatedBytes } }
    var checkedItems: [ContentItem] { checked.values.sorted(by: order.precedes) }

    func load(_ inventory: ContentInventory, offset: Int = 0) async {
        let token = UUID()
        generation = token
        let initialInspections = inspectionTokens
        isLoading = true
        self.offset = offset
        let kinds = kinds, search = search, order = order, pageSize = pageSize
        do {
            let result: ContentPage
            if let path = inventory.indexPath {
                result = try await Task.detached(priority: .utility) {
                    try ContentIndex(path: path).page(kinds: kinds, search: search, order: order, offset: offset, limit: pageSize, excluding: inventory.removedPaths ?? [])
                }.value
            } else {
                // Pre-index snapshots stay reviewable until their replacement scan finishes.
                result = await Task.detached(priority: .utility) {
                let matching = inventory.summaries.filter { kinds.isEmpty || kinds.contains($0.kind) }
                    .flatMap(\.largestItems).filter { search.isEmpty || $0.path.localizedStandardContains(search) }
                    .sorted(by: order.precedes)
                return ContentPage(items: Array(matching.dropFirst(offset).prefix(pageSize)), count: matching.count)
                }.value
            }
            guard token == generation else { return }
            if result.items.isEmpty && result.count > 0 && offset > 0 {
                await load(inventory, offset: ((result.count - 1) / pageSize) * pageSize)
                return
            }
            items = result.items
            focused.formIntersection(Set(items.map(\.path)))
            if focused.isEmpty, let first = items.first { focused = [first.path] }
            count = result.count
            error = nil
        } catch {
            guard token == generation else { return }
            self.error = "File index unavailable. Scan again to rebuild it."
            items = []
            count = 0
        }
        if token == generation {
            isLoading = false
            let result = await protectionCheck(items)
            guard token == generation, !Task.isCancelled else { return }
            let statuses = result.filter { inspectionTokens[$0.key] == initialInspections[$0.key] }
            let visible = Set(items.map(\.path))
            protection = statuses.merging(protection.filter { (checked[$0.key] != nil || visible.contains($0.key)) && statuses[$0.key] == nil }) { new, _ in new }
            for (path, status) in statuses where status != .untracked { checked.removeValue(forKey: path) }
        }
    }

    func toggle(_ item: ContentItem) {
        if checked[item.path] != nil { checked.removeValue(forKey: item.path) }
        else if protection[item.path] == .untracked { checked[item.path] = item }
    }
    func toggleFocused() {
        let selected = items.filter { focused.contains($0.path) }
        let remove = !selected.isEmpty && selected.allSatisfy { checked[$0.path] != nil }
        for item in selected {
            if remove { checked.removeValue(forKey: item.path) } else if protection[item.path] == .untracked { checked[item.path] = item }
        }
    }
    func checkPage() { for item in items where protection[item.path] == .untracked { checked[item.path] = item } }
    func checkProtection(_ item: ContentItem) async {
        let request = UUID(), page = generation
        inspectionTokens[item.path] = request
        let statuses = await FileGitProtection().statuses(for: [item], inspectContainers: true)
        guard generation == page, inspectionTokens[item.path] == request else { return }
        protection.merge(statuses) { _, new in new }
        if statuses[item.path] != .untracked { checked.removeValue(forKey: item.path) }
    }
    func clear() { checked.removeAll() }
    func removeChecked(_ paths: Set<String>) {
        for path in paths { checked.removeValue(forKey: path); protection.removeValue(forKey: path) }
        items.removeAll { paths.contains($0.path) }
        focused.subtract(paths)
    }
}
