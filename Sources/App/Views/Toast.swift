import SwiftUI

/// Toast message types.
enum ToastKind: Sendable {
    case success, error, info

    var systemImage: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .error: .red
        case .info: .accentColor
        }
    }
}

struct ToastMessage: Identifiable, Sendable {
    let id = UUID()
    let kind: ToastKind
    let text: String
}

/// Presents a transient toast notification at the bottom of the view.
struct ToastView: View {
    let message: ToastMessage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: message.kind.systemImage)
                .foregroundStyle(message.kind.color)
                .font(.callout)

            Text(message.text)
                .font(.callout)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        )
        .frame(maxWidth: 420)
    }
}

/// Modifier that displays toasts with automatic dismissal.
struct ToastOverlay: ViewModifier {
    @Binding var toasts: [ToastMessage]

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                ForEach(toasts) { toast in
                    ToastView(message: toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 20)
            .animation(.spring(duration: 0.3), value: toasts.map(\.id))
        }
    }
}

extension View {
    func toasts(_ toasts: Binding<[ToastMessage]>) -> some View {
        modifier(ToastOverlay(toasts: toasts))
    }
}
