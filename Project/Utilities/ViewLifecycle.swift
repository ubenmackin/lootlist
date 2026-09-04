//
//  ViewLifecycle.swift
//  LootList
//
//  Created by Ben Mackin on 8/27/26.
//

import SwiftUI

// Centralizes view model initialization, single-flight rebuilds, and sync subscription.

enum ViewLifecycle {
    /// Ensures `storage` holds a ViewModel, creating it via `factory` only
    /// when nil. Returns the existing or newly created instance.
    @discardableResult
    static func ensure<T>(_ storage: inout T?, factory: () -> T) -> T {
        if let existing = storage {
            return existing
        }
        let vm = factory()
        storage = vm
        return vm
    }

    /// Idempotent ensure + rebuild: creates the ViewModel if needed, then
    /// invokes `rebuild` exactly once. Prevents redundant @Query-driven
    /// rebuild() calls that previously ran after both ensure and manualSync.
    static func ensureAndRebuild<T>(
        _ storage: inout T?,
        factory: () -> T,
        rebuild: (T) -> Void
    ) {
        let vm = ensure(&storage, factory: factory)
        rebuild(vm)
    }
}

// MARK: - ViewModifiers

/// Single-task appearance modifier. Replaces the duplicated
/// `onAppear { ensureViewModel(); rebuild() }` + `.task { ensureViewModel(); rebuild() }`
/// pair with one `.task` that runs once per appearance.
struct ViewModelLifecycleModifier: ViewModifier {
    let ensure: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.task { @MainActor in ensure() }
    }
}

/// Appearance modifier managing lifecycle subscription and single-flight rebuild.
struct SyncedViewModelLifecycleModifier: ViewModifier {
    let ensure: @MainActor () -> Void
    let subscribe: @MainActor () -> Void
    let unsubscribe: @MainActor () -> Void
    let sync: (@MainActor () async -> Void)?

    func body(content: Content) -> some View {
        content
            .task { @MainActor in
                ensure()
                subscribe()
                if let sync {
                    await sync()
                }
            }
            .onDisappear { unsubscribe() }
    }
}

extension View {
    /// Replaces duplicated `onAppear` + `.task` ensure/rebuild boilerplate.
    func viewModelLifecycle(ensure: @MainActor @escaping () -> Void) -> some View {
        modifier(ViewModelLifecycleModifier(ensure: ensure))
    }

    /// For Views that need sync-event subscription. Keeps subscribe/unsubscribe
    /// paired and ensures only a single rebuild per appearance.
    func syncedViewModelLifecycle(
        ensure: @MainActor @escaping () -> Void,
        subscribe: @MainActor @escaping () -> Void,
        unsubscribe: @MainActor @escaping () -> Void,
        sync: (@MainActor () async -> Void)? = nil
    ) -> some View {
        modifier(SyncedViewModelLifecycleModifier(
            ensure: ensure,
            subscribe: subscribe,
            unsubscribe: unsubscribe,
            sync: sync
        ))
    }
}
