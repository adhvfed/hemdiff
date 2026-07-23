import Foundation

enum ArtifactKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case rustTarget
    case nodeModules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rustTarget: "Rust target"
        case .nodeModules: "node_modules"
        }
    }

    var folderName: String {
        switch self {
        case .rustTarget: "target"
        case .nodeModules: "node_modules"
        }
    }

    var markerName: String {
        switch self {
        case .rustTarget: "Cargo.toml"
        case .nodeModules: "package.json"
        }
    }
}

struct Artifact: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let kind: ArtifactKind
    let path: String
    let projectPath: String
    let allocatedBytes: Int64
    let createdAt: Date?
    let modifiedAt: Date?
    let worktreeName: String?

    init(
        kind: ArtifactKind,
        path: String,
        projectPath: String,
        allocatedBytes: Int64,
        createdAt: Date?,
        modifiedAt: Date?,
        worktreeName: String? = nil
    ) {
        self.kind = kind
        self.path = path
        self.projectPath = projectPath
        self.allocatedBytes = allocatedBytes
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.worktreeName = worktreeName
        id = "\(kind.rawValue):\(URL(fileURLWithPath: path).standardizedFileURL.path)"
    }

    var url: URL { URL(fileURLWithPath: path) }
    var projectURL: URL { URL(fileURLWithPath: projectPath) }
    var projectName: String { projectURL.lastPathComponent }
}

struct ScannedCategory: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let allocatedBytes: Int64
}

struct DiskSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let roots: [String]
    let startedAt: Date
    let finishedAt: Date
    let filesVisited: Int
    let directoriesVisited: Int
    let errorsSkipped: Int
    var categories: [ScannedCategory]
    var artifacts: [Artifact]

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
        copy.artifacts.removeAll { ids.contains($0.id) }
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
}

struct ReclaimResult: Sendable {
    let reclaimedIDs: Set<Artifact.ID>
    let reclaimedBytes: Int64
    let failures: [String: String]
}

enum ByteText {
    static func string(_ bytes: Int64, style: ByteCountFormatter.CountStyle = .file) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = style
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: bytes)
    }

    static func compact(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: bytes)
    }
}
