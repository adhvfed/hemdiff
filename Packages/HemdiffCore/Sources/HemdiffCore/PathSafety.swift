import Foundation

public enum PathSafety {
    public static func contains(_ url: URL, in root: URL) -> Bool {
        url.standardizedFileURL.pathComponents.starts(with: root.standardizedFileURL.pathComponents)
    }

    // Check every component, including ancestors above the selected folder.
    // macOS's system aliases are permitted only with their standard destinations.
    public static func hasSymbolicLink(in url: URL) -> Bool {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path) {
                #if os(macOS)
                let systemAliases = ["/tmp": "/private/tmp", "/var": "/private/var", "/etc": "/private/etc"]
                guard let expected = systemAliases[candidate.path],
                      destination == expected || destination == String(expected.dropFirst()) else { return true }
                #else
                return true
                #endif
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return false
    }

    public static func isDirectory(_ url: URL) -> Bool {
        guard !hasSymbolicLink(in: url),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
        return values.isDirectory == true
    }

    public static func textFile(_ url: URL) -> String? {
        guard !hasSymbolicLink(in: url),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= 65_536 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
