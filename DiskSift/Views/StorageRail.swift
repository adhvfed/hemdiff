import SwiftUI

struct StorageRail: View {
    let volume: VolumeSnapshot
    let rustBytes: Int64
    let nodeBytes: Int64
    let appleBytes: Int64

    private var segments: (rust: Double, node: Double, apple: Double, other: Double, free: Double) {
        let total = max(1, Double(volume.totalBytes))
        let used = min(Double(volume.usedBytes), total)
        let rust = min(Double(rustBytes), used)
        let node = min(Double(nodeBytes), max(0, used - rust))
        let apple = min(Double(appleBytes), max(0, used - rust - node))
        let other = max(0, used - rust - node - apple)
        let free = max(0, total - used)
        return (rust / total, node / total, apple / total, other / total, free / total)
    }

    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 3
            let width = max(0, proxy.size.width - gap * 4)
            HStack(spacing: gap) {
                railSegment(color: DiskSiftTheme.rust, width: width * segments.rust)
                railSegment(color: DiskSiftTheme.node, width: width * segments.node)
                railSegment(color: DiskSiftTheme.xcode, width: width * segments.apple)
                railSegment(color: .primary.opacity(0.72), width: width * segments.other)
                railSegment(color: .primary.opacity(0.10), width: width * segments.free)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .animation(.easeOut(duration: 0.35), value: rustBytes + nodeBytes + appleBytes)
        }
        .frame(height: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(Int(volume.usedFraction * 100)) percent used. \(ByteText.compact(volume.availableBytes)) available."
        )
    }

    private func railSegment(color: Color, width: CGFloat) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(0, width))
    }
}

struct StorageLegend: View {
    let snapshot: DiskSnapshot
    let volume: VolumeSnapshot

    private var otherBytes: Int64 {
        max(0, volume.usedBytes - snapshot.artifactBytes)
    }

    private var appleBytes: Int64 {
        snapshot.bytes(for: .xcodeDerivedData) + snapshot.bytes(for: .swiftBuild)
    }

    var body: some View {
        HStack(spacing: 22) {
            legendItem("Rust target", bytes: snapshot.bytes(for: .rustTarget), color: DiskSiftTheme.rust)
            legendItem("node_modules", bytes: snapshot.bytes(for: .nodeModules), color: DiskSiftTheme.node)
            legendItem("Xcode / SwiftPM", bytes: appleBytes, color: DiskSiftTheme.xcode)
            legendItem("Other used", bytes: otherBytes, color: .primary.opacity(0.72))
            Spacer(minLength: 8)
            legendItem("Available", bytes: volume.availableBytes, color: .primary.opacity(0.16))
        }
    }

    private func legendItem(_ title: String, bytes: Int64, color: Color) -> some View {
        HStack(spacing: 7) {
            Rectangle()
                .fill(color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(ByteText.compact(bytes))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
        }
    }
}
