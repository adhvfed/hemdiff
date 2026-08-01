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
        case .nodeModules: node
        case .xcodeDerivedData, .swiftBuild: xcode
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
