//
//  ToastManager.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import SwiftUI

/// Severity/category for a toast banner. Each case carries the SF Symbol name and
/// tint color used by ``ToastView`` when rendering the banner.
enum ToastType: Sendable {
    case error
    case warning
    case success
    case info

    /// SF Symbol used as the leading icon in the banner.
    var systemImage: String {
        switch self {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    /// Tint applied to the icon and (where supported) the banner accent.
    var color: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .success: .green
        case .info: .blue
        }
    }
}

/// A single dismissible toast banner queued for presentation.
struct Toast: Identifiable, Sendable {
    let id: UUID
    let message: String
    let type: ToastType
    /// Optional action invoked when the user taps the toast body. The toast is
    /// always dismissed by the X button regardless of whether this is set.
    let dismissAction: (@Sendable () -> Void)?

    init(id: UUID = UUID(),
         message: String,
         type: ToastType,
         dismissAction: (@Sendable () -> Void)? = nil)
    {
        self.id = id
        self.message = message
        self.type = type
        self.dismissAction = dismissAction
    }
}

/// Identity-based equality for `Toast` so `ToastView`'s
/// `.animation(_:value:)` modifier can detect changes in the toasts array.
/// Equality is keyed on `id` only (a UUID); two toasts sharing an id are
/// treated as the same presentation intent. Closures are not Equatable, so
/// synthesis is impossible — this manual conformance is required.
extension Toast: Equatable {
    static func == (lhs: Toast, rhs: Toast) -> Bool {
        lhs.id == rhs.id
    }
}

/// Global toast banner presenter. Observable, main-actor isolated, injected via
/// `@Environment` from `LootListApp`. Toasts stack newest-first (index 0 is the
/// newest) and auto-dismiss after a fixed delay.
@MainActor
@Observable
final class ToastManager {
    /// Currently presented toasts. Index `0` is the newest (topmost) banner.
    private(set) var toasts: [Toast] = []

    /// Auto-dismiss delay for newly shown toasts.
    private static let autoDismissDuration: UInt64 = AppConstants.UserInterface.toastAutoDismissNanos // 7 seconds

    /// Active auto-dismiss tasks keyed by toast id, so we can cancel them when a
    /// toast is dismissed manually before the timer elapses.
    private var autoDismissTasks: [UUID: Task<Void, Never>] = [:]

    init() {}

    /// Presents a new toast of the given type and schedules auto-dismissal.
    /// Deduplicates identical toasts (same message and type) by refreshing the existing
    /// toast's auto-dismiss timer instead of inserting duplicate banners.
    @discardableResult
    func show(message: String,
              type: ToastType = .info,
              dismissAction: (@Sendable () -> Void)? = nil) -> UUID
    {
        // Deduplication: if an identical toast is already active, refresh its timer and avoid stacking duplicates.
        if let existing = toasts.first(where: { $0.message == message && $0.type == type }) {
            scheduleAutoDismiss(for: existing.id)
            return existing.id
        }

        // Cap the maximum simultaneous toasts to 3 to prevent screen flooding.
        if toasts.count >= 3, let oldest = toasts.last {
            dismiss(id: oldest.id)
        }

        let toast = Toast(message: message, type: type, dismissAction: dismissAction)
        // New toasts go to the top of the stack (newest first).
        toasts.insert(toast, at: 0)
        scheduleAutoDismiss(for: toast.id)
        return toast.id
    }

    /// Removes the toast with the given id (if present) and cancels its
    /// auto-dismiss task. Safe to call from any context that hops back to
    /// MainActor; idempotent if the toast was already removed.
    func dismiss(id: UUID) {
        guard let index = toasts.firstIndex(where: { $0.id == id }) else {
            // Still ensure no dangling scheduled task lingers for this id.
            autoDismissTasks.removeValue(forKey: id)?.cancel()
            return
        }
        toasts.remove(at: index)
        autoDismissTasks.removeValue(forKey: id)?.cancel()
    }

    /// Removes all presented toasts and cancels any pending auto-dismiss tasks.
    func clear() {
        toasts.removeAll()
        for task in autoDismissTasks.values {
            task.cancel()
        }
        autoDismissTasks.removeAll()
    }

    /// Schedules a non-blocking auto-dismiss. The sleep runs off the main thread
    /// and hops back to MainActor only to remove the toast by id.
    private func scheduleAutoDismiss(for id: UUID) {
        autoDismissTasks[id]?.cancel()
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AppConstants.UserInterface.toastAutoDismissSeconds))
            if !Task.isCancelled {
                self?.dismiss(id: id)
            }
        }
        autoDismissTasks[id] = task
    }
}
