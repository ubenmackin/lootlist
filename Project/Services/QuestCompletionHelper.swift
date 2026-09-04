//
//  QuestCompletionHelper.swift
//  LootList
//
//  Created by Ben Mackin on 8/31/26.
//

import Foundation
import os
import SwiftUI

/// DRY helper for quest multi-part completion celebration branching.
///
/// Extracts the duplicated 15-line pattern found in `ChildHubView` and
/// `MyChoresView` (priorApproved count, isFinalSubPart check, and
/// haptics/toast vs celebration) into a single place.
enum QuestCompletionHelper {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestCompletionHelper")

    // MARK: - isFinalSubPart

    /// Whether the next approved completion would fill the quest's target.
    /// Computes `priorApproved` from the supplied logs filtered to the quest.
    static func isFinalSubPart(quest: QuestCache, logs: [QuestCompletionCache]) -> Bool {
        let priorApproved = logs.filter { $0.questRecordName == quest.recordName && $0.isApproved }.count
        return isFinalSubPart(quest: quest, priorApproved: priorApproved)
    }

    /// Whether `priorApproved + 1` reaches the quest's targetCount.
    static func isFinalSubPart(quest: QuestCache, priorApproved: Int) -> Bool {
        priorApproved + 1 >= quest.targetCount
    }

    // MARK: - handleCompletionResult

    /// Pure branching helper that classifies a completion for callers that
    /// want to drive their own UI. Provided to satisfy the three-parameter
    /// contract while keeping the richer side-effect overloads available.
    @discardableResult
    static func handleCompletionResult(_ completion: QuestCompletion, quest: QuestCache, priorApproved: Int) -> CompletionOutcome {
        if completion.verificationStatus == .autoApproved {
            if isFinalSubPart(quest: quest, priorApproved: priorApproved) {
                return .finalCelebration
            }
            return .partialProgress(part: priorApproved + 1, total: quest.targetCount)
        } else if completion.verificationStatus == .pending {
            return .pendingReview
        }
        return .noFeedback
    }

    /// Side-effecting helper that drives haptics, toasts, and the confetti
    /// celebration. The celebration is driven via a `Binding<Bool>` so the
    /// helper can own the `confettiLifetime` dismissal sleep.
    @MainActor
    static func handleCompletionResult(
        _ completion: QuestCompletion,
        quest: QuestCache,
        priorApproved: Int,
        toastManager: ToastManager?,
        showCelebration: Binding<Bool>
    ) {
        handleCompletionResult(
            completion,
            quest: quest,
            priorApproved: priorApproved,
            toastManager: toastManager,
            triggerCelebration: {
                showCelebration.wrappedValue = true
                Task {
                    do {
                        try await Task.sleep(for: .seconds(DesignSystemConstants.Celebration.confettiLifetime))
                    } catch {
                        logger.debug("Celebration dismiss sleep interrupted: \(error, privacy: .private)")
                    }
                    showCelebration.wrappedValue = false
                }
            }
        )
    }

    /// Side-effecting helper with an explicit celebration closure. Allows
    /// callers that manage `showCelebration` differently to inject their own
    /// presentation while still sharing haptics/toast branching.
    @MainActor
    static func handleCompletionResult(
        _ completion: QuestCompletion,
        quest: QuestCache,
        priorApproved: Int,
        toastManager: ToastManager?,
        triggerCelebration: @MainActor @escaping () -> Void
    ) {
        switch handleCompletionResult(completion, quest: quest, priorApproved: priorApproved) {
        case .finalCelebration:
            HapticsService.success()
            triggerCelebration()
        case let .partialProgress(part, total):
            HapticsService.lightImpact()
            toastManager?.show(message: "Part \(part) of \(total) complete! \u{1F3AF}", type: .success)
        case .pendingReview:
            HapticsService.lightImpact()
            toastManager?.show(message: "Quest sent to Parent for review! \u{23F3}", type: .info)
        case .noFeedback:
            break
        }
    }

    // MARK: - Outcome

    enum CompletionOutcome: Equatable, Sendable {
        case finalCelebration
        case partialProgress(part: Int, total: Int)
        case pendingReview
        case noFeedback
    }
}
