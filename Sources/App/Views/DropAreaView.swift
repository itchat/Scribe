import SwiftUI
import UniformTypeIdentifiers

/// Drag-and-drop area for video files using modern `.dropDestination` API.
struct DropAreaView: View {
    var compact: Bool = false
    var onDrop: ([URL]) -> Void

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            if compact {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                    .overlay {
                        Label("Drop more videos here", systemImage: "plus.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(
                                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5, dash: [10, 6])
                                )
                        }
                        .animation(.easeInOut(duration: 0.15), value: isTargeted)

                    VStack(spacing: 14) {
                        Image(systemName: isTargeted ? "arrow.down.doc.fill" : "film.stack")
                            .font(.system(size: 52, weight: .light))
                            .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                            .symbolEffect(.bounce, value: isTargeted)

                        VStack(spacing: 4) {
                            Text("Drop Videos Here")
                                .font(.title3.weight(.medium))
                            Text("MP4 · AVI · MOV · MKV · FLV · WMV")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .padding(compact ? 8 : 28)
        .dropDestination(for: URL.self) { urls, _ in
            // Filter video files only
            let videoURLs = urls.filter { url in
                let ext = url.pathExtension.lowercased()
                return ["mp4", "avi", "mov", "mkv", "flv", "wmv"].contains(ext)
            }
            guard !videoURLs.isEmpty else { return false }
            onDrop(videoURLs)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
    }
}
