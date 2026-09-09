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
    private var generation = UUID()
    let pageSize = 250
    var checkedBytes: Int64 { checked.values.reduce(0) { $0 + $1.allocatedBytes } }
    var checkedItems: [ContentItem] { checked.values.sorted(by: order.precedes) }

    func load(_ inventory: ContentInventory, offset: Int = 0) async {
        let token = UUID()
        generation = token
        isLoading = true
        self.offset = offset
        let kinds = kinds, search = search, order = order, pageSize = pageSize
        do {
            let result: ContentPage
            if let path = inventory.indexPath {
                result = try await Task.detached(priority: .utility) {
                    try ContentIndex(path: path).page(kinds: kinds, search: search, order: order, offset: offset, limit: pageSize)
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
            items = result.items
            count = result.count
            error = nil
        } catch {
            guard token == generation else { return }
            self.error = "File index unavailable. Scan again to rebuild it."
            items = []
            count = 0
        }
        if token == generation { isLoading = false }
    }

    func toggle(_ item: ContentItem) {
        if checked[item.path] != nil { checked.removeValue(forKey: item.path) }
        else { checked[item.path] = item }
    }
    func toggleFocused() {
        let selected = items.filter { focused.contains($0.path) }
        let remove = !selected.isEmpty && selected.allSatisfy { checked[$0.path] != nil }
        for item in selected {
            if remove { checked.removeValue(forKey: item.path) } else { checked[item.path] = item }
        }
    }
    func checkPage() { for item in items { checked[item.path] = item } }
    func clear() { checked.removeAll() }
    func removeChecked(_ paths: Set<String>) { for path in paths { checked.removeValue(forKey: path) } }
}
