import SwiftUI

struct ClipRow: View {
    let item: ClipItem
    let thumbnail: NSImage?
    let isSelecting: Bool
    let isSelected: Bool
    let justCopied: Bool
    let onTap: () -> Void
    let onDelete: () -> Void
    let onSelectMode: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                    .padding(.top, 2)
                    .transition(.scale.combined(with: .opacity))
            }

            Image(nsImage: AppIconCache.icon(for: item.app))
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                content
                HStack(spacing: 4) {
                    Text(item.app.displayName).lineLimit(1)
                    Text("·")
                    Text(item.detailLabel).lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 6) {
                Text(Self.timeFormatter.string(from: item.createdAt))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                ZStack {
                    if justCopied {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    } else if hovering && !isSelecting {
                        Button(action: onDelete) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("삭제")
                    }
                }
                .frame(width: 18, height: 18)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: justCopied)
        .contextMenu {
            Button { onTap() } label: { Label("복사", systemImage: "doc.on.doc") }
            if item.kind == .files {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(item.filePaths.map { URL(fileURLWithPath: $0) })
                } label: { Label("Finder에서 보기", systemImage: "folder") }
            }
            if !isSelecting {
                Button(action: onSelectMode) { Label("선택하기", systemImage: "checkmark.circle") }
            }
            Divider()
            Button(role: .destructive, action: onDelete) { Label("삭제", systemImage: "trash") }
        }
    }

    private var rowBackground: Color {
        if isSelected { return Theme.accent.opacity(0.10) }
        if justCopied { return Color.green.opacity(0.10) }
        if hovering { return Theme.hoverFill(scheme) }
        return .clear
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            Text(item.previewText)
                .font(.system(size: 13))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .image:
            VStack(alignment: .leading, spacing: 4) {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 200, maxHeight: 96, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Theme.cardStroke(scheme), lineWidth: 1)
                        )
                } else {
                    Label("이미지", systemImage: "photo")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                if !item.previewText.isEmpty {
                    Text(item.previewText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        case .files:
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(item.filePaths.prefix(3).enumerated()), id: \.offset) { _, path in
                    HStack(spacing: 5) {
                        Image(nsImage: AppIconCache.fileIcon(path: path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text((path as NSString).lastPathComponent)
                            .font(.system(size: 13))
                            .lineLimit(1)
                    }
                }
                if item.filePaths.count > 3 {
                    Text("외 \(item.filePaths.count - 3)개")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
