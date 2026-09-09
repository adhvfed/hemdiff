import AppKit
import Quartz
import SwiftUI

extension ContentKind {
    var color: Color {
        switch self {
        case .video, .images: .purple
        case .audio: .pink
        case .archives, .diskImages: DiskSiftTheme.rust
        case .logs: .orange
        case .sourceCode, .models: DiskSiftTheme.node
        case .virtualMachines, .applications: .blue
        case .databases: .indigo
        case .documents: .cyan
        case .other: .secondary
        }
    }
}

struct SpaceHero: View {
    let title: String
    let bytes: Int64
    let subtitle: String
    var color: Color = DiskSiftTheme.node
    var fraction: Double = 0
    var trailing: String = ""
    var isAvailable = true

    var body: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                Text(isAvailable ? ByteText.compact(bytes) : "—")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .tracking(-1.5).monospacedDigit().contentTransition(.numericText())
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            ZStack {
                Circle().stroke(color.opacity(0.12), lineWidth: 9)
                Circle().trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "arrow.down.right")
                    .font(.system(size: 27, weight: .medium)).foregroundStyle(color)
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
            if !trailing.isEmpty { Text(trailing).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18).fill(.background.secondary)
            RoundedRectangle(cornerRadius: 18).fill(LinearGradient(colors: [color.opacity(0.12), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: 18).strokeBorder(color.opacity(0.22), lineWidth: 0.75)
        }
    }
}

struct FileItemTable: View {
    let items: [ContentItem]
    @Binding var focused: Set<String>
    let checked: Set<String>
    let toggle: (ContentItem) -> Void
    let toggleFocused: () -> Void
    let preview: (ContentItem) -> Void
    var compact = false

    var body: some View {
        Table(items, selection: $focused) {
            TableColumn("") { item in
                Button { toggle(item) } label: {
                    Image(systemName: checked.contains(item.path) ? "checkmark.square.fill" : "square")
                        .font(.system(size: 16)).foregroundStyle(checked.contains(item.path) ? DiskSiftTheme.node : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(checked.contains(item.path) ? "Uncheck" : "Check") \(item.url.lastPathComponent)")
            }.width(24)
            TableColumn("File") { item in
                HStack(spacing: 10) {
                    Image(systemName: item.kind.icon).font(.system(size: 18)).foregroundStyle(item.kind.color).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.url.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                        Text(item.url.deletingLastPathComponent().path.abbreviatingHome)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }.padding(.vertical, 6).help(item.path)
            }.width(min: 140, ideal: compact ? 140 : 300, max: .infinity)
            TableColumn("On disk") { item in
                Text(ByteText.string(item.allocatedBytes)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }.width(85)
            TableColumn("Modified") { item in
                Text(item.modifiedAt?.formatted(date: .abbreviated, time: .omitted) ?? "—").foregroundStyle(.secondary)
            }.width(90)
        }
        .onKeyPress(.space) { toggleFocused(); return .handled }
        .contextMenu(forSelectionType: String.self) { ids in
            if let item = items.first(where: { ids.contains($0.path) }) {
                Button("Preview") { preview(item) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.path, forType: .string)
                }
            }
        } primaryAction: { ids in
            if let item = items.first(where: { ids.contains($0.path) }) { preview(item) }
        }
    }
}

struct FilePreview: View {
    let item: ContentItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.url.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            QuickLookFile(url: item.url)
        }.frame(minWidth: 560, minHeight: 420)
    }
}

private struct QuickLookFile: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
}

struct FileConfirmation: Identifiable {
    let id = UUID()
    let items: [ContentItem]
    let permanent: Bool
}

struct FileConfirmationSheet: View {
    @EnvironmentObject private var model: AppModel
    let confirmation: FileConfirmation
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(confirmation.permanent ? "Delete from Trash?" : "Move to Trash?", systemImage: confirmation.permanent ? "trash.slash" : "trash")
                .font(.title2.weight(.semibold))
            Text("\(confirmation.items.count.formatted()) items · \(ByteText.string(confirmation.items.reduce(0) { $0 + $1.allocatedBytes }))")
                .font(.title3).monospacedDigit()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(confirmation.items) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.url.lastPathComponent).font(.callout.weight(.medium))
                                Text(item.path.abbreviatingHome).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(ByteText.string(item.allocatedBytes)).font(.caption).monospacedDigit()
                        }
                    }
                }
            }.frame(maxHeight: 240)
            Text(confirmation.permanent ? "Permanent deletion cannot be undone. Shared blocks and open files may reduce the space recovered." : "You can restore these items from Finder. Space is recovered when Trash is emptied.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmation.permanent ? "Delete Permanently" : "Move to Trash", role: .destructive) {
                    dismiss()
                    confirm()
                }.buttonStyle(.borderedProminent).tint(confirmation.permanent ? DiskSiftTheme.rust : DiskSiftTheme.node).disabled(model.isBusy)
            }
        }.padding(24).frame(width: 560)
        .onAppear { model.isReviewingDeletion = true }
        .onDisappear { model.isReviewingDeletion = false }
    }
}

struct ModelMessages: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let error = model.errorMessage {
            message(error, icon: "exclamationmark.triangle", tint: .orange) { model.errorMessage = nil }
        }
        if let notice = model.noticeMessage {
            message(notice, icon: "checkmark.circle", tint: DiskSiftTheme.node) { model.noticeMessage = nil }
        }
    }
    private func message(_ text: String, icon: String, tint: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Label(text, systemImage: icon).font(.callout).foregroundStyle(tint)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).help("Dismiss message")
        }.padding(12).background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ReviewSearchField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.plain).focused($focused)
            if !text.isEmpty {
                Button { text = ""; focused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Clear search")
            }
        }.padding(.horizontal, 10).padding(.vertical, 7)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? DiskSiftTheme.node : Color.primary.opacity(0.1), lineWidth: 1))
            .background { Button("Find") { focused = true }.keyboardShortcut("f").hidden() }
            .onExitCommand { text = "" }
    }
}
