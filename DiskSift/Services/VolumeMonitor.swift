import Foundation

struct VolumeMonitor: Sendable {
    func measure(at url: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> VolumeSnapshot {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        let total = (attributes[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let values = try? url.resourceValues(forKeys: [.volumeNameKey])

        return VolumeSnapshot(
            name: values?.volumeName ?? "Macintosh HD",
            totalBytes: total,
            availableBytes: free,
            measuredAt: Date()
        )
    }
}
