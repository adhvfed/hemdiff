import Foundation

/// Project markers establish ownership; names alone never make a generic build folder reclaimable.
enum ArtifactRules {
    static func matches(_ kind: ArtifactKind, project: URL) -> Bool {
        guard kind.markerNames.contains(where: { regularFile(project.appendingPathComponent($0)) }) else { return false }
        if kind == .terraformProviders {
            // Never treat the .terraform container, backend metadata, state, or lockfile as output.
            guard let files = try? FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil) else { return false }
            return files.contains { ["tf", "tofu"].contains($0.pathExtension) && regularFile($0) }
        }
        return true
    }

    static func containsArtifact(_ url: URL) -> Bool {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            for kind in ArtifactKind.allCases where !kind.isKnownContainerArtifact {
                if candidate.path.hasSuffix("/" + kind.folderName) {
                    let project = kind.folderName.split(separator: "/").reduce(candidate) { root, _ in root.deletingLastPathComponent() }
                    if matches(kind, project: project) { return true }
                }
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return false
    }

    private static func regularFile(_ url: URL) -> Bool {
        guard !PathSafety.hasSymbolicLink(in: url),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
