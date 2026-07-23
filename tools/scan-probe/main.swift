import Foundation

@main
enum DiskSiftScanProbe {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else {
            FileHandle.standardError.write(
                Data("usage: disksift-scan-probe <root> [--automatic]\n".utf8)
            )
            Foundation.exit(64)
        }

        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let started = ContinuousClock.now
        let snapshot: DiskSnapshot
        if CommandLine.arguments.contains("--automatic") {
            snapshot = try await ArtifactScanner().scan(
                configuration: ScanConfiguration(
                    automaticDiscoveryRoot: root,
                    explicitRoots: []
                )
            )
        } else {
            snapshot = try await ArtifactScanner().scan(roots: [root])
        }
        let elapsed = started.duration(to: .now)

        print("root=\(root.path)")
        print("duration=\(elapsed.formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)))")
        print("files=\(snapshot.filesVisited)")
        print("directories=\(snapshot.directoriesVisited)")
        print("artifacts=\(snapshot.artifacts.count)")
        print("artifact_bytes=\(snapshot.artifactBytes)")
        print("errors_skipped=\(snapshot.errorsSkipped)")
    }
}
