import SwiftUI

enum DiskSiftTheme {
    static let rust = Color(red: 0.91, green: 0.34, blue: 0.20)
    static let node = Color(red: 0.12, green: 0.63, blue: 0.62)
    static let xcode = Color(red: 0.48, green: 0.42, blue: 0.86)
    static let ink = Color(red: 0.08, green: 0.12, blue: 0.16)
    static let paper = Color(red: 0.965, green: 0.965, blue: 0.94)
    static let darkPaper = Color(red: 0.055, green: 0.085, blue: 0.11)

    static func color(for kind: ArtifactKind) -> Color {
        switch kind {
        case .rustTarget: rust
        case .nodeModules, .nextBuild, .turboCache: node
        case .xcodeDerivedData, .swiftBuild: xcode
        case .terraformProviders: .blue
        case .pytestCache, .ruffCache, .mypyCache: .yellow
        case .mavenTarget, .gradleBuild: .orange
        }
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(20)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator.opacity(0.6), lineWidth: 0.5)
            }
    }
}

struct StatusMessage: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Shared controls keep keyboard behavior while giving actions a clear hierarchy.
struct HemdiffButtonStyle: ButtonStyle {
    enum Emphasis { case secondary, primary, destructive }
    var emphasis: Emphasis = .secondary
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let prominent = emphasis != .secondary
        let accent = emphasis == .destructive ? Color(red: 0.72, green: 0.23, blue: 0.13) : Color(red: 0.08, green: 0.43, blue: 0.43)
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 13).padding(.vertical, 9)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(prominent ? accent : Color.primary.opacity(scheme == .dark ? 0.075 : 0.045))
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white.opacity(configuration.isPressed ? 0 : hovered ? 0.10 : 0))
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(prominent ? Color.white.opacity(0.14) : Color.primary.opacity(hovered ? 0.22 : 0.12), lineWidth: 1)
            }
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onHover { hovered = $0 }
    }
}

struct ReviewEmptyState: View {
    let title: String
    let detail: String
    let icon: String
    var fillsSpace = true
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 30, weight: .light))
                .foregroundStyle(DiskSiftTheme.node)
                .frame(width: 68, height: 68)
                .background(DiskSiftTheme.node.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
            Text(title).font(.system(size: 21, weight: .semibold, design: .rounded))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: fillsSpace ? .infinity : nil).padding(24)
    }
}
