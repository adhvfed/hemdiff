import Foundation
import UniformTypeIdentifiers

enum ContentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case video, audio, images, documents, archives, diskImages, virtualMachines
    case models, databases, sourceCode, applications, binaries, fonts, developerData, logs, other

    var id: String { rawValue }
    var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .images: "Images"
        case .documents: "Documents"
        case .archives: "Archives"
        case .diskImages: "Disk images & installers"
        case .virtualMachines: "Virtual machines"
        case .models: "AI models"
        case .databases: "Databases & datasets"
        case .sourceCode: "Code & configuration"
        case .applications: "Applications"
        case .binaries: "Binaries & libraries"
        case .fonts: "Fonts"
        case .developerData: "Developer indexes & state"
        case .logs: "Logs"
        case .other: "Other files"
        }
    }

    var icon: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .images: "photo"
        case .documents: "doc.text"
        case .archives: "archivebox"
        case .diskImages: "opticaldisc"
        case .virtualMachines: "desktopcomputer"
        case .models: "cpu"
        case .databases: "externaldrive"
        case .sourceCode: "curlybraces"
        case .applications: "app"
        case .binaries: "terminal"
        case .fonts: "textformat"
        case .developerData: "tray.2"
        case .logs: "text.alignleft"
        case .other: "doc"
        }
    }

    static let classificationVersion = 2

    /// Use explicit formats first, then the system type registry. Never read file contents.
    static func classify(_ url: URL, isDirectory: Bool = false) -> ContentKind {
        let ext = url.pathExtension.lowercased()
        if isDirectory {
            switch ext {
            case "app": return .applications
            case "mlmodelc", "mlpackage": return .models
            case "vmwarevm", "pvm", "utm": return .virtualMachines
            case "photoslibrary", "photolibrary": return .images
            case "sparsebundle": return .diskImages
            case "pages", "numbers", "key": return .documents
            default: return .other
            }
        }
        let name = url.lastPathComponent.lowercased()
        let parts = name.split(separator: ".")
        // Strong filename conventions, without opening files or traversing repositories.
        if name.hasPrefix("terraform-provider-") || name.hasPrefix("tofu-provider-") { return .binaries }
        if name.contains(".so.") && name.split(separator: ".").last.map({ Int($0) != nil }) == true { return .binaries }
        if name.hasPrefix(".env.") || name.hasPrefix("dockerfile.") || name.hasPrefix(".git") && [".gitignore", ".gitattributes", ".gitmodules", ".gitconfig"].contains(name) { return .sourceCode }
        if ["cmakelists.txt", "makefile", "gnumakefile", "dockerfile", "containerfile", "gemfile", "rakefile", "justfile", "procfile", "brewfile", ".npmrc", ".yarnrc", ".editorconfig", ".env", ".bashrc", ".zshrc"].contains(name) { return .sourceCode }
        if ["license", "licence", "readme", "notice", "authors", "changelog", "copying"].contains(name) { return .documents }
        if ["pytorch_model.bin", "adapter_model.bin", "diffusion_pytorch_model.bin"].contains(name) { return .models }
        if name.hasSuffix(".sqlite-wal") || name.hasSuffix(".sqlite-shm") || name.hasSuffix(".db-wal") || name.hasSuffix(".db-shm") { return .databases }
        if let logIndex = parts.lastIndex(of: "log"), logIndex + 1 < parts.count {
            let suffix = parts[(logIndex + 1)...]
            if suffix.allSatisfy({ ["gz", "zst", "bz2", "xz"].contains(String($0)) || $0.allSatisfy({ $0.isNumber || $0 == "-" }) }) { return .logs }
        }
        if parts.contains("log") && (ext == "log" || Int(ext) != nil || ["gz", "zst", "bz2", "xz"].contains(ext)) { return .logs }
        switch ext {
        case "bin", "dat", "pt", "pth", "ckpt": return .other
        case "dylib", "so", "dll", "exe", "a", "o", "obj", "lib", "wasm", "class", "jar", "war", "node", "pyc", "pyo": return .binaries
        case "ttf", "otf", "woff", "woff2", "ttc": return .fonts
        case "npy", "npz", "feather", "avro", "orc", "rdb", "mdb", "duckdb", "ndjson": return .databases
        case "ipynb", "vue", "svelte", "astro", "mjs", "cjs", "cts", "map", "less", "sass", "styl", "mdx", "lua", "pl", "pm", "ex", "exs", "erl", "hrl", "hs", "lhs", "clj", "cljs", "scala", "sc", "dart", "zig", "cmake", "gradle", "tf", "tfvars", "proto", "graphql", "gql", "conf", "cfg", "properties", "plist", "nix", "bazel", "bzl", "sln", "csproj", "cs", "fs", "fsx", "ps1", "bat", "cmd": return .sourceCode
        case "gguf", "ggml", "safetensors", "onnx", "mlmodel", "mlmodelc": return .models
        case "vmdk", "vdi", "vhd", "vhdx", "qcow", "qcow2": return .virtualMachines
        case "dmg", "iso", "img", "sparseimage", "pkg", "mpkg": return .diskImages
        case "zip", "7z", "rar", "tar", "gz", "bz2", "xz", "zst", "tgz", "tbz2": return .archives
        case "sqlite", "sqlite3", "db", "db3", "parquet", "arrow", "h5", "hdf5", "csv", "tsv": return .databases
        case "rs", "swift", "py", "js", "jsx", "ts", "tsx", "c", "h", "cpp", "hpp", "go", "java", "kt", "rb", "sh", "zsh", "fish", "sql", "html", "css", "scss", "json", "jsonl", "yaml", "yml", "toml", "xml", "ini", "lock": return .sourceCode
        case "mp4", "mkv", "mov", "avi", "webm", "m4v", "mts": return .video
        case "mp3", "wav", "flac", "aac", "m4a", "ogg", "aiff", "opus": return .audio
        case "jpg", "jpeg", "png", "heic", "gif", "tiff", "webp", "svg", "raw", "dng", "psd": return .images
        case "pdf", "txt", "md", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "epub": return .documents
        default: break
        }
        if ["makefile", "dockerfile", "gemfile", ".gitignore", ".env"].contains(url.lastPathComponent.lowercased()) {
            return .sourceCode
        }
        let path = url.path.lowercased()
        if path.contains("/.metadata/.plugins/org.eclipse.")
            || path.contains("/.cache/clangd/index/")
            || path.contains("/index.noindex/")
            || path.contains("/.swiftpm/security/") { return .developerData }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .archive) { return .archives }
        if type.conforms(to: .sourceCode) { return .sourceCode }
        if type.conforms(to: .text) || type.conforms(to: .pdf) { return .documents }
        return .other
    }
}

struct ContentItem: Codable, Hashable, Identifiable, Sendable {
    var id: String { path }
    let path: String
    let kind: ContentKind
    let allocatedBytes: Int64
    let modifiedAt: Date?
    let isPackage: Bool
    var stamp: FileStamp? = nil
    var url: URL { URL(fileURLWithPath: path) }
}

struct ContentSummary: Codable, Equatable, Identifiable, Sendable {
    var id: ContentKind { kind }
    let kind: ContentKind
    var count: Int = 0
    var allocatedBytes: Int64 = 0
    var largestItems: [ContentItem] = []
}

struct ContentInventory: Codable, Equatable, Sendable {
    static let itemLimitPerKind = 100
    var summaries: [ContentSummary] = []
    var errorsSkipped = 0
    var indexPath: String? = nil
    var removedPaths: [String]? = nil
    var count: Int { summaries.reduce(0) { $0 + $1.count } }
    var allocatedBytes: Int64 { summaries.reduce(0) { $0 + $1.allocatedBytes } }

    /// Legacy snapshots retain only their largest items; remove known entries without inventing totals.
    func removing(paths: [String]) -> ContentInventory {
        var copy = self
        copy.removedPaths = Array(Set((removedPaths ?? []) + paths))
        for i in copy.summaries.indices {
            let removed = copy.summaries[i].largestItems.filter { item in
                paths.contains { item.path == $0 || item.path.hasPrefix($0 + "/") }
            }
            let ids = Set(removed.map(\.path))
            copy.summaries[i].largestItems.removeAll { ids.contains($0.path) }
            copy.summaries[i].count = max(0, copy.summaries[i].count - removed.count)
            copy.summaries[i].allocatedBytes = max(0, copy.summaries[i].allocatedBytes - removed.reduce(0) { $0 + $1.allocatedBytes })
        }
        copy.summaries.removeAll { $0.count == 0 }
        return copy
    }
}

struct ContentInventoryBuilder {
    var index: ContentIndex? = nil
    init(index: ContentIndex? = nil) { self.index = index }
    private var summaries: [ContentKind: ContentSummary] = [:]
    var errorsSkipped = 0

    mutating func record(_ item: ContentItem) {
        var summary = summaries[item.kind] ?? ContentSummary(kind: item.kind)
        summary.count += 1
        summary.allocatedBytes += item.allocatedBytes
        if summary.largestItems.count < ContentInventory.itemLimitPerKind
            || summary.largestItems.last.map({ Self.precedes(item, $0) }) == true {
            let position = summary.largestItems.firstIndex { Self.precedes(item, $0) } ?? summary.largestItems.endIndex
            summary.largestItems.insert(item, at: position)
            if summary.largestItems.count > ContentInventory.itemLimitPerKind { summary.largestItems.removeLast() }
        }
        summaries[item.kind] = summary
    }

    private static func precedes(_ lhs: ContentItem, _ rhs: ContentItem) -> Bool {
        lhs.allocatedBytes == rhs.allocatedBytes ? lhs.path < rhs.path : lhs.allocatedBytes > rhs.allocatedBytes
    }

    var inventory: ContentInventory {
        ContentInventory(summaries: summaries.values.sorted {
            $0.allocatedBytes == $1.allocatedBytes ? $0.kind.rawValue < $1.kind.rawValue : $0.allocatedBytes > $1.allocatedBytes
        }, errorsSkipped: errorsSkipped)
    }
}
