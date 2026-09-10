import Foundation

public enum ReclaimValidationError: LocalizedError, Equatable {
    case missing
    case symbolicLink
    case unexpectedPath
    case changedSinceScan
    case missingProjectMarker
    case missingContainer

    public var errorDescription: String? {
        switch self {
        case .missing: "The folder no longer exists."
        case .symbolicLink: "Symbolic links can’t be deleted here."
        case .unexpectedPath: "The folder no longer matches the scanned project."
        case .changedSinceScan: "Folder changed since the scan. Scan again."
        case .missingProjectMarker: "The project marker no longer exists."
        case .missingContainer: "The known storage container no longer exists."
        }
    }
}

public struct ArtifactReclaimer: Sendable {
    private let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    public func validate(_ artifact: Artifact) throws {
        guard !PathSafety.hasSymbolicLink(in: artifact.url) else {
            throw ReclaimValidationError.symbolicLink
        }
        if artifact.kind.isKnownContainerArtifact {
            try validateKnownContainerArtifact(artifact)
            return
        }

        let url = artifact.url.standardizedFileURL
        let projectURL = artifact.projectURL.standardizedFileURL
        let expectedURL = projectURL
            .appendingPathComponent(artifact.kind.folderName, isDirectory: true)
            .standardizedFileURL

        guard url == expectedURL,
              PathSafety.contains(url, in: projectURL), url != projectURL
        else {
            throw ReclaimValidationError.unexpectedPath
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ReclaimValidationError.missing
        }

        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ReclaimValidationError.symbolicLink
        }

        guard try ArtifactFileIdentity.capture(at: url) == artifact.fileIdentity else {
            throw ReclaimValidationError.changedSinceScan
        }

        var isProjectDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: projectURL.path,
            isDirectory: &isProjectDirectory
        ), isProjectDirectory.boolValue
        else {
            throw ReclaimValidationError.missingProjectMarker
        }
        let projectValues = try projectURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard projectValues.isSymbolicLink != true else {
            throw ReclaimValidationError.symbolicLink
        }

        guard ArtifactRules.matches(artifact.kind, project: projectURL) else {
            throw ReclaimValidationError.missingProjectMarker
        }
    }

    private func validateKnownContainerArtifact(_ artifact: Artifact) throws {
        let url = artifact.url.standardizedFileURL
        let containerURL = artifact.projectURL.standardizedFileURL
        let expectedContainer = ArtifactContainers
            .xcodeDerivedDataRoot(in: homeDirectory)

        guard artifact.kind == .xcodeDerivedData,
              containerURL == expectedContainer,
              url.deletingLastPathComponent() == containerURL,
              url.lastPathComponent != containerURL.lastPathComponent
        else {
            throw ReclaimValidationError.unexpectedPath
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: containerURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue
        else {
            throw ReclaimValidationError.missingContainer
        }
        let containerValues = try containerURL.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        )
        guard containerValues.isSymbolicLink != true else {
            throw ReclaimValidationError.symbolicLink
        }

        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ReclaimValidationError.missing
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ReclaimValidationError.symbolicLink
        }

        guard try ArtifactFileIdentity.capture(at: url) == artifact.fileIdentity else {
            throw ReclaimValidationError.changedSinceScan
        }
    }

}
