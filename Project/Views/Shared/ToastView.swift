//
//  ToastView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

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
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button, style: .continuous)
                .strokeBorder(toast.type.color.opacity(0.35), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button, style: .continuous))
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
    func toastOverlay() -> some View {
        modifier(ToastOverlayModifier())
    }

    func celebrationOverlay() -> some View {
        modifier(CelebrationOverlayModifier())
    }
}

struct CelebrationOverlayModifier: ViewModifier {
    @Environment(CelebrationManager.self) private var celebrationManager

    func body(content: Content) -> some View {
        content
            .overlay {
                CelebrationOverlay(isPresented: celebrationManager.isConfettiShowing)
            }
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
