import Foundation

enum ReclaimValidationError: LocalizedError, Equatable {
    case missing
    case symbolicLink
    case unexpectedName
    case missingProjectMarker

    var errorDescription: String? {
        switch self {
        case .missing: "The folder no longer exists."
        case .symbolicLink: "Symbolic links cannot be reclaimed."
        case .unexpectedName: "The folder name changed since the scan."
        case .missingProjectMarker: "The project marker no longer exists."
        }
    }
}

struct ArtifactReclaimer: Sendable {
    func validate(_ artifact: Artifact) throws {
        let url = artifact.url.standardizedFileURL
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
        guard url.lastPathComponent == artifact.kind.folderName else {
            throw ReclaimValidationError.unexpectedName
        }
        let marker = url.deletingLastPathComponent()
            .appendingPathComponent(artifact.kind.markerName)
        guard FileManager.default.fileExists(atPath: marker.path) else {
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
