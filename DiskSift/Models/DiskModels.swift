import Foundation

enum ArtifactKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case rustTarget
    case nodeModules
    case nextBuild
    case xcodeDerivedData
    case swiftBuild
    case turboCache, terraformProviders, pytestCache, ruffCache, mypyCache, mavenTarget, gradleBuild

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rustTarget: "Rust target"
        case .nodeModules: "node_modules"
        case .nextBuild: "Next.js .next"
        case .xcodeDerivedData: "Xcode DerivedData"
        case .swiftBuild: "SwiftPM .build"
        case .turboCache: "Turbo cache"
        case .terraformProviders: "Terraform / OpenTofu providers"
        case .pytestCache: "pytest cache"
        case .ruffCache: "Ruff cache"
        case .mypyCache: "mypy cache"
        case .mavenTarget: "Maven target"
        case .gradleBuild: "Gradle build"
        }
    }

    var folderName: String {
        switch self {
        case .rustTarget: "target"
        case .nodeModules: "node_modules"
        case .nextBuild: ".next"
        case .xcodeDerivedData: "DerivedData"
        case .swiftBuild: ".build"
        case .turboCache: ".turbo/cache"
        case .terraformProviders: ".terraform/providers"
        case .pytestCache: ".pytest_cache"
        case .ruffCache: ".ruff_cache"
        case .mypyCache: ".mypy_cache"
        case .mavenTarget: "target"
        case .gradleBuild: "build"
        }
    }

    var markerName: String? { markerNames.first }

    var markerNames: [String] {
        switch self {
        case .rustTarget: ["Cargo.toml"]
        case .nodeModules, .nextBuild: ["package.json"]
        case .xcodeDerivedData: []
        case .swiftBuild: ["Package.swift"]
        case .turboCache: ["turbo.json", "turbo.jsonc"]
        case .terraformProviders: [".terraform.lock.hcl"]
        case .pytestCache: ["pyproject.toml", "pytest.ini", "setup.cfg"]
        case .ruffCache: ["pyproject.toml", "ruff.toml", ".ruff.toml"]
        case .mypyCache: ["pyproject.toml", "mypy.ini", ".mypy.ini", "setup.cfg"]
        case .mavenTarget: ["pom.xml"]
        case .gradleBuild: ["build.gradle", "build.gradle.kts"]
        }
    }

    var consequence: String {
        switch self {
        case .nodeModules: "Dependencies must be installed again."
        case .terraformProviders: "Run tofu init or terraform init to download providers again. State and lockfiles are kept."
        case .nextBuild: "Stop the Next.js server first. Rebuild before running next start."
        case .turboCache, .pytestCache, .ruffCache, .mypyCache: "The next run recreates the cache."
        default: "Build output will be recreated on the next build."
        }
    }

    var family: String {
        switch self {
        case .rustTarget: "Rust"
        case .nodeModules, .nextBuild, .turboCache: "Node"
        case .swiftBuild, .xcodeDerivedData: "Swift / Xcode"
        case .terraformProviders: "Infrastructure"
        case .pytestCache, .ruffCache, .mypyCache: "Python"
        case .mavenTarget, .gradleBuild: "JVM"
        }
    }

    var isKnownContainerArtifact: Bool {
        self == .xcodeDerivedData
    }
}

struct ArtifactFileIdentity: Codable, Hashable, Sendable {
    let volume: UInt64
    let file: UInt64

    static func capture(at url: URL) throws -> ArtifactFileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            throw CocoaError(.fileReadUnknown)
        }
        return ArtifactFileIdentity(volume: volume, file: file)
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
    let fileIdentity: ArtifactFileIdentity

    init(
        kind: ArtifactKind,
        path: String,
        projectPath: String,
        allocatedBytes: Int64,
        createdAt: Date?,
        modifiedAt: Date?,
        worktreeName: String? = nil,
        fileIdentity: ArtifactFileIdentity
    ) {
        self.kind = kind
        self.path = path
        self.projectPath = projectPath
        self.allocatedBytes = allocatedBytes
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.worktreeName = worktreeName
        self.fileIdentity = fileIdentity
        id = "\(kind.rawValue):\(URL(fileURLWithPath: path).standardizedFileURL.path)"
    }

    var url: URL { URL(fileURLWithPath: path) }
    var projectURL: URL { URL(fileURLWithPath: projectPath) }
    var projectName: String {
        switch kind {
        case .xcodeDerivedData:
            if url.lastPathComponent == "ModuleCache.noindex" {
                return "Module cache"
            }
            return url.lastPathComponent
        default:
            return projectURL.lastPathComponent
        }
    }
}

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
