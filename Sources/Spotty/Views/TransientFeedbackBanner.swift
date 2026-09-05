import SwiftUI

/// Non-modal overlay for the current mutation-feedback message.
///
/// Hit-testing and focus stay with the content underneath. Presentation lives
/// in an overlay so the persistent player layout does not shift.
struct TransientFeedbackBanner: View {
    let feedback: TransientFeedbackPresenter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let message = feedback.message {
                banner(message)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: feedback.message?.id)
        .allowsHitTesting(false)
        .accessibilityRespondsToUserInteraction(false)
        .onChange(of: feedback.message?.id) { _, _ in
            guard let message = feedback.message else { return }
            let announcement = AccessibilityNotification.Announcement(spokenText(for: message))
            announcement.post()
        }
    }

    private func banner(_ message: TransientFeedbackMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol(for: message.kind))
                .foregroundStyle(iconStyle(for: message.kind))
                .accessibilityHidden(true)
            Text(message.text)
                .font(.callout)
                .foregroundStyle(SpottyPalette.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.separator.opacity(0.35))
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
        .focusable(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenText(for: message))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func symbol(for kind: TransientFeedbackKind) -> String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .informational: "info.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    private func iconStyle(for kind: TransientFeedbackKind) -> some ShapeStyle {
        switch kind {
        case .success, .informational: Color.secondary
        case .failure: Color.orange
        }
    }

    private func spokenText(for message: TransientFeedbackMessage) -> String {
        switch message.kind {
        case .success:
            "Success. \(message.text)"
        case .informational:
            message.text
        case .failure:
            "Alert. \(message.text)"
        }
    }
}
