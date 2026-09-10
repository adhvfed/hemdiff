import AppKit
import AVKit
import ImageIO
import Quartz
import SwiftUI

/// Selection-following preview. Decode images to the display size, never full resolution.
struct MediaPreview: View {
    let item: ContentItem
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var loaded = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.16)
            if item.kind == .images, let image {
                Image(nsImage: image).resizable().scaledToFit().padding(12)
            } else if (item.kind == .video || item.kind == .audio), let player {
                VideoPlayer(player: player)
            } else if loaded {
                QuickLookFile(url: item.url)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: item.path) {
            player?.pause(); player = nil; image = nil; loaded = false
            if item.kind == .video || item.kind == .audio {
                player = AVPlayer(url: item.url)
            } else if item.kind == .images {
                let url = item.url
                let work = Task.detached(priority: .userInitiated) { () -> CGImage? in
                    guard !Task.isCancelled,
                          let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                    else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1600,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary)
                }
                let thumbnail = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled else { return }
                if let thumbnail { image = NSImage(cgImage: thumbnail, size: .zero) }
            }
            guard !Task.isCancelled else { return }
            loaded = true
        }
        .onDisappear { player?.pause(); player = nil }
    }
}

struct FileInspector: View {
    let item: ContentItem
    let protection: FileGitStatus?
    let checked: Bool
    let toggle: () -> Void
    let expand: () -> Void
    let checkProtection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                Button(action: expand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Expand preview · ⌘Y")
            }
            MediaPreview(item: item).frame(minHeight: 180, idealHeight: 260, maxHeight: 380)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(item.url.lastPathComponent).font(.headline).textSelection(.enabled).lineLimit(3)
            HStack {
                Label(item.kind.title, systemImage: item.kind.icon).foregroundStyle(item.kind.color)
                Spacer()
                Text(ByteText.string(item.allocatedBytes)).monospacedDigit()
            }.font(.caption)
            Divider()
            Label(protection == .tracked ? "Protected by Git" : protection == .untracked ? "Not tracked by Git" : "Protection not verified",
                  systemImage: protection == .untracked ? "checkmark.shield" : "lock.shield")
                .font(.callout.weight(.medium)).foregroundStyle(protection == .tracked ? Color.orange : Color.secondary)
            if protection == .tracked {
                Text("Tracked files stay in your project.").font(.caption).foregroundStyle(.secondary)
            } else if protection != .untracked {
                Button("Check Protection", action: checkProtection)
            }
            Text(item.url.deletingLastPathComponent().path.abbreviatingHome)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let modified = item.modifiedAt {
                Text("Modified \(modified.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Spacer(minLength: 0)
                Button(checked ? "Uncheck" : "Check", action: toggle)
                    .disabled(!checked && protection != .untracked)
            }
        }.padding(16).frame(width: 290)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .buttonStyle(HemdiffButtonStyle())
    }
}
