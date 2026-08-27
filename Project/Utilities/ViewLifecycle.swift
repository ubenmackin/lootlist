//
//  ViewLifecycle.swift
//  LootList
//
//  Created by Ben Mackin on 8/27/26.
//

import SwiftUI

// WHY: Eleven Views duplicated the same nil-checked viewModel creation,
// rebuild(), and subscribeToSyncEvents pattern across onAppear + .task,
// causing double rebuild churn and ad-hoc sync triggers outside
// AppLifecycleCoordinator. Centralizing here keeps appearance handling
// single-flight and sync coordination in one place.

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
    let ensure: () -> Void

    func body(content: Content) -> some View {
        content.task { ensure() }
    }
}

/// Appearance modifier for Views that also subscribe to sync events.
/// Calls ensure → subscribe → rebuild once on appear, and unsubscribes
/// on disappear. The optional `sync` closure runs after rebuild if a
/// manual sync is still desired, but without an extra redundant rebuild
/// — sync triggers remain centralized in AppLifecycleCoordinator.
struct SyncedViewModelLifecycleModifier: ViewModifier {
    let ensure: () -> Void
    let subscribe: () -> Void
    let unsubscribe: () -> Void
    let sync: (() async -> Void)?

    func body(content: Content) -> some View {
        content
            .task {
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
    func viewModelLifecycle(ensure: @escaping () -> Void) -> some View {
        modifier(ViewModelLifecycleModifier(ensure: ensure))
    }

    /// For Views that need sync-event subscription. Keeps subscribe/unsubscribe
    /// paired and ensures only a single rebuild per appearance.
    func syncedViewModelLifecycle(
        ensure: @escaping () -> Void,
        subscribe: @escaping () -> Void,
        unsubscribe: @escaping () -> Void,
        sync: (() async -> Void)? = nil
    ) -> some View {
        modifier(SyncedViewModelLifecycleModifier(
            ensure: ensure,
            subscribe: subscribe,
            unsubscribe: unsubscribe,
            sync: sync
        ))
    }
}
