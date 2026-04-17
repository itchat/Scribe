import SwiftUI

/// Rich video row with thumbnail, metadata, and inline progress.
struct VideoItemView: View {
    let item: VideoItem

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                metadataLine

                if item.state == .processing {
                    ProgressView(value: Double(item.progress), total: 100)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }

                statusLine
            }

            Spacer()

            trailingAccessory
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background.secondary.opacity(item.state == .processing ? 0.6 : 0.3))
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .draggable(draggableURL) {
            // Drag preview
            HStack(spacing: 6) {
                Image(systemName: "film")
                Text(item.fileName)
                    .lineLimit(1)
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Returns the best URL to drag out: output video if completed, otherwise source video.
    private var draggableURL: URL {
        if case .completed = item.state,
           let output = item.result?.outputVideoURL {
            return output
        }
        if case .completed = item.state,
           let subtitle = item.result?.subtitleURL {
            return subtitle
        }
        return item.url
    }

    // MARK: - Thumbnail

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)

            if let img = item.thumbnail {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }

            if item.state == .completed {
                stateBadge(systemName: "checkmark.circle.fill", color: .green)
            } else if item.state == .failed {
                stateBadge(systemName: "exclamationmark.circle.fill", color: .red)
            } else if item.state == .processing {
                stateBadge(systemName: "waveform", color: .accentColor)
            }
        }
        .frame(width: 60, height: 40)
    }

    private func stateBadge(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(3)
            .background(Circle().fill(.background))
            .offset(x: 24, y: 14)
    }

    // MARK: - Metadata

    @ViewBuilder
    private var metadataLine: some View {
        let parts: [String] = [
            item.resolution ?? "",
            item.durationFormatted,
            item.fileSizeFormatted,
        ].filter { !$0.isEmpty }

        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Status

    private var statusLine: some View {
        Text(item.status)
            .font(.caption)
            .foregroundStyle(statusColor)
            .lineLimit(1)
    }

    private var statusColor: Color {
        switch item.state {
        case .queued: .secondary
        case .processing: .primary
        case .completed: .green
        case .failed: .red
        }
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailingAccessory: some View {
        switch item.state {
        case .queued:
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
        case .processing:
            Text("\(item.progress)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .completed:
            EmptyView()
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
