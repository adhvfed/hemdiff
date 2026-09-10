import Foundation
import HemdiffCore

typealias FileGitStatus = GitTrackingStatus

struct FileGitProtection: Sendable {
    /// Call once for a visible page or selected batch, never once per row.
    func statuses(for items: [ContentItem], inspectContainers: Bool = false) async -> [String: FileGitStatus] {
        let work = Task.detached(priority: .utility) {
            GitTracking.statuses(for: items.map(\.url), inspectContainers: inspectContainers, cancelled: { Task.isCancelled })
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: { work.cancel() }
    }
}
