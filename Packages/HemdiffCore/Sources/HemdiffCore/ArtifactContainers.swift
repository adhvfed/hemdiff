import Foundation

/// Canonical locations shared by discovery and validation.
public enum ArtifactContainers {
    public static func xcodeDerivedDataRoot(in home: URL) -> URL {
        home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
            .standardizedFileURL
    }
}
