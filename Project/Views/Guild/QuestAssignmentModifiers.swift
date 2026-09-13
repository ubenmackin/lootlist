//
//  QuestAssignmentModifiers.swift
//  LootList
//
//  Created by Ben Mackin on 9/13/26.
//

import SwiftUI

/// WHY split assignment lifecycle into a typed modifier: deep onChange chains stall the Swift 6 type-checker.
struct AssignmentLifecycleModifier: ViewModifier {
    let cachedCompletions: [QuestCompletionCache]
    let cachedTemplates: [QuestTemplateCache]
    let cachedProfiles: [ProfileCache]
    let cachedAssignments: [QuestCache]
    let onAppear: () -> Void
    let onCompletionsChanged: () -> Void
    let onCacheChanged: () -> Void

    func body(content: Content) -> some View {
        applyTail(to: applyHead(to: content))
    }

    private func applyHead(to content: Content) -> some View {
        content
            .onAppear { onAppear() }
            .onChange(of: cachedCompletions) { _, _ in onCompletionsChanged() }
            .onChange(of: cachedTemplates) { _, _ in onCacheChanged() }
    }

    private func applyTail(to view: some View) -> some View {
        view
            .onChange(of: cachedProfiles) { _, _ in onCacheChanged() }
            .onChange(of: cachedAssignments) { _, _ in onCacheChanged() }
    }
}

/// WHY split dialogs into a typed modifier: alert plus overlays widen Form inference.
struct AssignmentDialogsModifier: ViewModifier {
    @Binding var showOverrideAlert: Bool
    var isEditAmountFocused: FocusState<Bool>.Binding
    var editAmountText: Binding<String>?
    let onOverride: () -> Void

    func body(content: Content) -> some View {
        content
            .alert("Override Lock?", isPresented: $showOverrideAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Override", role: .destructive) {
                    onOverride()
                }
            } message: {
                Text("Hero has already started this quest. Changing the assignee will move this quest. Continue?")
            }
            .toastOverlay()
            .decimalPadDoneToolbar(isFocused: isEditAmountFocused, amountText: editAmountText)
    }
}
