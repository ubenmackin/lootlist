//
//  ToastView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

/// Top-anchored overlay banner stack rendered above all other content by the
/// app root. Reads ``ToastManager`` from the environment and stacks each pending
/// toast newest-first. Tap the body to invoke the toast's optional
/// `dismissAction`; tap the X button to dismiss without invoking the action.
struct ToastView: View {
    let toastManager: ToastManager

    var body: some View {
        VStack(spacing: 10) {
            ForEach(toastManager.toasts) { toast in
                toastRow(for: toast)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.snappy, value: toastManager.toasts)
        .allowsHitTesting(!toastManager.toasts.isEmpty)
    }

    private func toastRow(for toast: Toast) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: toast.type.systemImage)
                .font(.title3)
                .foregroundStyle(toast.type.color)
                .accessibilityHidden(true)

            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                toastManager.dismiss(id: toast.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(toast.type.color.opacity(0.35), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            if let dismissAction = toast.dismissAction {
                dismissAction()
            }
            if toast.dismissAction != nil {
                toastManager.dismiss(id: toast.id)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(toast.type.localizedDescription) toast")
        .accessibilityValue(toast.message)
        .accessibilityHint(toast.dismissAction != nil ? "Double tap to activate" : "Use the dismiss button to close")
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private extension ToastType {
    /// VoiceOver-friendly severity label, prefixed to the toast's accessibility label.
    var localizedDescription: String {
        switch self {
        case .error: "Error"
        case .warning: "Warning"
        case .success: "Success"
        case .info: "Info"
        }
    }
}

extension View {
    /// Attaches the top-anchored ToastView overlay to any view or modal sheet navigation stack.
    func toastOverlay() -> some View {
        modifier(ToastOverlayModifier())
    }
}

struct ToastOverlayModifier: ViewModifier {
    @Environment(ToastManager.self) private var toastManager: ToastManager?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toastManager {
                    ToastView(toastManager: toastManager)
                }
            }
    }
}
