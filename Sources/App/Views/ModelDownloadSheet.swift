import SwiftUI

/// Sheet for downloading the ASR model.
struct ModelDownloadSheet: View {
    @Environment(\.dismiss) private var dismiss

    let isDownloading: Bool
    let progress: Double
    let isReady: Bool
    let onDownload: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("ASR Model (Parakeet v2)")
                .font(.title2)

            Text("English-only speech recognition model.\nRuns locally on Apple Neural Engine.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if isReady {
                Label("Model Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            } else if isDownloading {
                VStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)

                    Text("\(Int(progress * 100))% downloaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            } else {
                Text("Model not downloaded yet.")
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if !isReady && !isDownloading {
                    Button("Download Model") {
                        onDownload()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(30)
        .frame(minWidth: 400)
    }
}
