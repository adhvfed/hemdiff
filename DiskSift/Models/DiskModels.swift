import Foundation

struct ScannedCategory: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let allocatedBytes: Int64
}

struct DiskSnapshot: Codable, Equatable, Sendable {
    // Includes classified content from explicit scan locations.
    static let currentSchemaVersion = 11

    let schemaVersion: Int
    let roots: [String]
    let startedAt: Date
    let finishedAt: Date
    let filesVisited: Int
    let directoriesVisited: Int
    let errorsSkipped: Int
    var categories: [ScannedCategory]
    var artifacts: [Artifact]
    var content = ContentInventory()

    static var empty: DiskSnapshot {
        DiskSnapshot(
            schemaVersion: currentSchemaVersion,
            roots: [],
            startedAt: .distantPast,
            finishedAt: .distantPast,
            filesVisited: 0,
            directoriesVisited: 0,
            errorsSkipped: 0,
            categories: [],
            artifacts: []
        )
    }

    var artifactBytes: Int64 {
        artifacts.reduce(0) { $0 + $1.allocatedBytes }
    }

    func isFresh(at date: Date = Date(), maxAge: TimeInterval) -> Bool {
        guard finishedAt != .distantPast else { return false }
        let age = date.timeIntervalSince(finishedAt)
        return age >= 0 && age <= maxAge
    }

    func bytes(for kind: ArtifactKind) -> Int64 {
        artifacts.lazy
            .filter { $0.kind == kind }
            .reduce(0) { $0 + $1.allocatedBytes }
    }

    func removingArtifacts(withIDs ids: Set<Artifact.ID>) -> DiskSnapshot {
        var copy = self
        for artifact in artifacts where ids.contains(artifact.id) {
            if let index = copy.categories.indices
                .filter({ PathSafety.contains(artifact.projectURL, in: URL(fileURLWithPath: copy.categories[$0].path)) })
                .max(by: { copy.categories[$0].path.count < copy.categories[$1].path.count }) {
                let category = copy.categories[index]
                copy.categories[index] = ScannedCategory(
                    id: category.id, name: category.name, path: category.path,
                    allocatedBytes: max(0, category.allocatedBytes - artifact.allocatedBytes)
                )
            }
        }
        copy.artifacts.removeAll { ids.contains($0.id) }
        copy.categories.removeAll { $0.allocatedBytes == 0 }
        return copy
    }
}

struct VolumeSnapshot: Equatable, Sendable {
    let name: String
    let totalBytes: Int64
    let availableBytes: Int64
    let measuredAt: Date

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }
}

struct ScanProgress: Equatable, Sendable {
    let currentPath: String
    let entriesVisited: Int
    let artifactsFound: Int
    let bytesMeasured: Int64
    var filesClassified: Int = 0

    var summary: String {
        filesClassified > 0 ? "\(filesClassified.formatted()) items classified" : "\(artifactsFound) folders measured"
    }
}

enum ByteText {
    static func string(_ bytes: Int64, style: ByteCountFormatter.CountStyle = .file) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = style
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    static func compact(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}
