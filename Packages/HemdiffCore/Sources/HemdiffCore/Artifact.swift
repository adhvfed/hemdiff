import Foundation

public enum ArtifactKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case rustTarget
    case nodeModules
    case nextBuild
    case xcodeDerivedData
    case swiftBuild
    case turboCache, terraformProviders, pytestCache, ruffCache, mypyCache, mavenTarget, gradleBuild

    public var id: String { rawValue }

    public var title: String {
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

    public var folderName: String {
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

    public var markerName: String? { markerNames.first }

    public var markerNames: [String] {
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

    public var consequence: String {
        switch self {
        case .nodeModules: "Dependencies must be installed again."
        case .terraformProviders: "Run tofu init or terraform init to download providers again. State and lockfiles are kept."
        case .nextBuild: "Stop the Next.js server first. Rebuild before running next start."
        case .turboCache, .pytestCache, .ruffCache, .mypyCache: "The next run recreates the cache."
        default: "Build output will be recreated on the next build."
        }
    }

    public var family: String {
        switch self {
        case .rustTarget: "Rust"
        case .nodeModules, .nextBuild, .turboCache: "Node"
        case .swiftBuild, .xcodeDerivedData: "Swift / Xcode"
        case .terraformProviders: "Infrastructure"
        case .pytestCache, .ruffCache, .mypyCache: "Python"
        case .mavenTarget, .gradleBuild: "JVM"
        }
    }

    public var isKnownContainerArtifact: Bool {
        self == .xcodeDerivedData
    }
}

public struct ArtifactFileIdentity: Codable, Hashable, Sendable {
    public let volume: UInt64
    public let file: UInt64

    public init(volume: UInt64, file: UInt64) {
        self.volume = volume
        self.file = file
    }

    public static func capture(at url: URL) throws -> ArtifactFileIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let file = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else {
            throw CocoaError(.fileReadUnknown)
        }
        return ArtifactFileIdentity(volume: volume, file: file)
    }
}

public struct Artifact: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let kind: ArtifactKind
    public let path: String
    public let projectPath: String
    public let allocatedBytes: Int64
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let worktreeName: String?
    public let fileIdentity: ArtifactFileIdentity

    public init(
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

    public var url: URL { URL(fileURLWithPath: path) }
    public var projectURL: URL { URL(fileURLWithPath: projectPath) }
    public var projectName: String {
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

public struct ReclaimResult: Sendable {
    public let reclaimedIDs: Set<Artifact.ID>
    public let reclaimedBytes: Int64
    public let failures: [String: String]

    public init(reclaimedIDs: Set<Artifact.ID>, reclaimedBytes: Int64, failures: [String: String]) {
        self.reclaimedIDs = reclaimedIDs
        self.reclaimedBytes = reclaimedBytes
        self.failures = failures
    }
}

