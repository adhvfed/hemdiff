import Foundation

enum ReclaimValidationError: LocalizedError, Equatable {
    case missing
    case symbolicLink
    case unexpectedPath
    case changedSinceScan
    case missingProjectMarker

    var errorDescription: String? {
        switch self {
        case .missing: "The folder no longer exists."
        case .symbolicLink: "Symbolic links cannot be reclaimed."
        case .unexpectedPath: "The folder no longer matches the scanned project."
        case .changedSinceScan: "The folder changed since the scan. Scan again before cleaning it."
        case .missingProjectMarker: "The project marker no longer exists."
        }
    }
}

struct ArtifactReclaimer: Sendable {
    func validate(_ artifact: Artifact) throws {
        let url = artifact.url.standardizedFileURL
        let projectURL = artifact.projectURL.standardizedFileURL
        let expectedURL = projectURL
            .appendingPathComponent(artifact.kind.folderName, isDirectory: true)
            .standardizedFileURL

        guard url == expectedURL,
              url.deletingLastPathComponent() == projectURL
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

        let marker = projectURL
            .appendingPathComponent(artifact.kind.markerName)
        guard FileManager.default.fileExists(atPath: marker.path) else {
            throw ReclaimValidationError.missingProjectMarker
        }
        let markerValues = try marker.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard markerValues.isRegularFile == true,
              markerValues.isSymbolicLink != true
        else {
            throw ReclaimValidationError.missingProjectMarker
        }
    }

    func reclaim(_ artifacts: [Artifact]) async -> ReclaimResult {
        await Task.detached(priority: .utility) {
            var reclaimedIDs = Set<Artifact.ID>()
            var reclaimedBytes: Int64 = 0
            var failures: [String: String] = [:]
            var seenPaths = Set<String>()

            for artifact in artifacts {
                let path = artifact.url.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }

                do {
                    try validate(artifact)
                    try FileManager.default.trashItem(
                        at: artifact.url.standardizedFileURL,
                        resultingItemURL: nil
                    )
                    reclaimedIDs.insert(artifact.id)
                    reclaimedBytes += artifact.allocatedBytes
                } catch {
                    failures[artifact.id] = error.localizedDescription
                }
            }

            return ReclaimResult(
                reclaimedIDs: reclaimedIDs,
                reclaimedBytes: reclaimedBytes,
                failures: failures
            )
        }.value
    }
}
