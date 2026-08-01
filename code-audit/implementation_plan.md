# Cache Architecture Hardening & Edge Case Remediation Plan

This implementation plan details the step-by-step changes to address all identified edge cases, conflict-detection gaps, UI re-entrancy risks, and query scoping improvements uncovered during the full architectural review of **LootList**.

## User Review Required

> [!NOTE]
> All changes preserve existing public service APIs and data model contracts. UI changes add micro-interaction protection (disabling buttons while mutations are in-flight) and uniform conflict error handling without breaking existing user flows.

## Open Questions

> [!NOTE]
> No unresolved design decisions or blocking questions. All changes align directly with the iOS 26 and Swift 6 architecture established in `ARCHITECTURE.md`.

---

## Proposed Changes

### Service Layer Alignment (`ConcurrentEditDetector`)

Unify conflict detection and toast notification across all mutation services so that `AchievementService` and `ManualSpendingService` align with `QuestService`, `TreasuryService`, `FamilyService`, and `XPService`.

#### [MODIFY] [AchievementService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/AchievementService.swift)
- In `award(_:to:family:)`, capture `preMutationChangeTag` and snapshot before optimistic write.
- Wrap the error catch block with `ConcurrentEditDetector.detectConcurrentEdit`.
- Display `.warning` toast when a concurrent edit is detected and re-fetch the authoritative record from CloudKit; otherwise display `.error` toast and restore the snapshot / invalidate uncommitted cache row.

#### [MODIFY] [SpendingService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/SpendingService.swift)
- In `ManualSpendingService.logManual` and `ManualSpendingService.delete`, capture value snapshots and `preMutationChangeTag` prior to local cache updates.
- Wrap catch blocks with `ConcurrentEditDetector.detectConcurrentEdit`.
- Re-fetch or restore pre-mutation snapshot on save failure and show appropriate warning/error toasts via `toastManager`.

---

### UI Layer Debouncing & Submitting State Guards

Prevent re-entrant rapid tapping on mutation buttons while async tasks are awaiting CloudKit completion.

#### [MODIFY] [HeroDashboardView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Hero/HeroDashboardView.swift)
- Add `@State private var submittingQuestIDs: Set<String> = []` to track active quest completion tasks.
- Disable `onComplete` trigger for a quest while its ID is in `submittingQuestIDs`.
- Update `init(familyRecordName:)` `@Query` predicates so that when `familyRecordName` is `nil`, the predicate filters for `$0.familyRecordName == ""` (returning an empty array) instead of passing `nil` (which fetches all families across the local database).

#### [MODIFY] [QuestDetailView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Hero/QuestDetailView.swift)
- Add `@State private var isSubmitting: Bool = false`.
- Disable "Mark Complete", "Verify", and "Reject" buttons and show inline spinner when `isSubmitting == true`.

#### [MODIFY] [LogSpendingView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Treasury/LogSpendingView.swift)
- Add `@State private var isSubmitting: Bool = false`.
- Disable "Add Entry" button and show progress indicator while saving manual spending.

#### [MODIFY] [QuestManagerView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Guild/QuestManagerView.swift)
- Add submitting state protection when creating quest templates, updating templates, or assigning quests to heroes.

---

### Test Suite Hardening

#### [NEW] [AchievementServiceTests.swift](file:///Users/kupan787/opencode/LootList/ProjectTests/Services/AchievementServiceTests.swift)
- Add unit tests verifying `AchievementService.award` optimistic cache write, snapshot rollback on save failure, and `ConcurrentEditDetector` handling.

#### [NEW] [ManualSpendingServiceTests.swift](file:///Users/kupan787/opencode/LootList/ProjectTests/Services/ManualSpendingServiceTests.swift)
- Add unit tests verifying `ManualSpendingService.logManual` and `delete` optimistic cache operations and snapshot rollback semantics.

---

## Verification Plan

### Automated Tests
Execute the unit test suite via `xcodebuild` or Swift Package manager test target:
```bash
xcodebuild test -project LootList.xcodeproj -scheme LootList -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

### Manual Verification
1. **Rapid Tap Prevention:** Open `HeroDashboardView` or `QuestDetailView`, tap "Mark Complete" rapidly, and verify only a single mutation task is triggered.
2. **Conflict Handling:** Simulate a CloudKit save error in unit tests and verify the pre-mutation snapshot is restored and the conflict warning toast is presented.
3. **Nil Family Scoping:** Verify `HeroDashboardView` initializes cleanly without fetching cross-family records when `familyRecordName` is `nil`.
