import Foundation

struct SnapshotStore: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = support
                .appendingPathComponent("DiskSift", isDirectory: true)
                .appendingPathComponent("snapshot.json", isDirectory: false)
        }
    }

    func load() throws -> DiskSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let version = try JSONDecoder().decode(SnapshotVersion.self, from: data)
        guard version.schemaVersion == DiskSnapshot.currentSchemaVersion else { return nil }
        return try JSONDecoder.diskSift.decode(DiskSnapshot.self, from: data)
    }

    func save(_ snapshot: DiskSnapshot) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.diskSift.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }
}

private struct SnapshotVersion: Decodable {
    let schemaVersion: Int
}

private extension JSONEncoder {
    static var diskSift: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var diskSift: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
