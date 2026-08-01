# LootList — Swift Codebase Audit Report

> **Scope:** 107 Swift source files across App, Models, Services, ViewModels, and Views layers
> **Date:** 2026-07-31
> **Methodology:** 5 parallel auditor agents performed exhaustive file-by-file review

---

## 1. Critical Bugs & Crash Hazards

These issues can cause data corruption, incorrect payouts, or runtime crashes in production.

---

### 1.1 `allOrNothing` Payout Logic Is Broken — Heroes Get Paid When They Shouldn't

**Files & Line Ranges:**
- [FamilyDashboardViewModel.swift](file:///Users/kupan787/opencode/LootList/Project/ViewModels/FamilyDashboardViewModel.swift):124-132
- [TreasuryViewModel.swift](file:///Users/kupan787/opencode/LootList/Project/ViewModels/TreasuryViewModel.swift):106-114

**Category:** Bug  
**Severity:** 🔴 Critical

**Issue:** The `allOrNothing` check compares `completedLogs.count < assignedQuests.count`. Because a quest with `targetCount > 1` generates multiple log entries, `completedLogs.count` can exceed `assignedQuests.count` even when other quests are ignored entirely. This means heroes can receive payouts they shouldn't under the strict "all-or-nothing" policy.

**Proposed Solution:**
```swift
// Compare unique fully-completed quests, not raw log counts
let fullyCompletedQuestIDs = Set(
    completedLogs
        .filter { $0.verificationStatusEnum != .rejected }
        .map { $0.questRecordName }
)
// A quest is "fully completed" only when its approved log count >= targetCount
let fullyCompletedCount = assignedQuests.filter { quest in
    let approvedLogs = completedLogs.filter {
        $0.questRecordName == quest.recordName &&
        $0.verificationStatusEnum != .rejected
    }
    return approvedLogs.count >= quest.targetCount
}.count

if hero.payoutPolicyEnum == .allOrNothing,
   !assignedQuests.isEmpty,
   fullyCompletedCount < assignedQuests.count {
    goldFromQuests = 0
}
```

---

### 1.2 Hero Dashboard Ignores `allOrNothing` Policy

**File & Line Range:** [HeroDashboardViewModel.swift](file:///Users/kupan787/opencode/LootList/Project/ViewModels/HeroDashboardViewModel.swift):162-190

**Category:** Bug  
**Severity:** 🔴 Critical

**Issue:** `earnedThisWeek(logs:quests:)` computes the hero's gold without checking the `allOrNothing` payout policy. Heroes see gold accumulating on their dashboard even when they haven't completed all quests, contradicting what the Treasury and Family Dashboard show.

**Proposed Solution:** Apply the corrected `allOrNothing` check (from §1.1) at the end of this function before returning `totalEarned`. This must use the same logic across all three ViewModels to ensure consistency.

---

### 1.3 `QuestCompletion` + XP Non-Atomic — Inconsistent State on Failure

**File & Line Range:** [QuestService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/QuestService.swift):89-145

**Category:** Bug  
**Severity:** 🔴 Critical

**Issue:** `completeQuest` creates a `QuestCompletion` record and then calls `xpService?.addXP`. If `addXP` fails (network error), the completion is already persisted in the cache — the quest shows as completed but XP isn't awarded. The two operations are not transactional.

**Proposed Solution:** Wrap both operations in coordinated error handling. If `addXP` fails, either:
- Roll back the completion from cache, or
- Queue the XP addition for retry with a `pendingXPGrants` mechanism

---

### 1.4 Weekly Payout — Two-Save Non-Atomic Operation

**File & Line Range:** [TreasuryService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/TreasuryService.swift):75-82

**Category:** Bug  
**Severity:** 🔴 High

**Issue:** `processWeeklyPayout` creates an `AllowancePeriod` and a `LedgerEntry` as two separate CloudKit saves. If the first succeeds but the second fails, the period is marked "paid" but no gold appears in the ledger. The hero's balance is silently wrong.

**Proposed Solution:** Use `CKModifyRecordsOperation` to save both records atomically:
```swift
let operation = CKModifyRecordsOperation(recordsToSave: [periodRecord, ledgerRecord])
operation.isAtomic = true
try await database.add(operation)
```

---

### 1.5 `CacheService` Force `try!` — Crash on Schema Migration Failure

**File & Line Range:** [CacheService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/CacheService.swift):30-42

**Category:** Bug  
**Severity:** 🔴 High

**Issue:** `try! ModelContainer(...)` in the initializer will crash if SwiftData cannot create the container (disk full, corrupted store, schema migration failure). The `FatalCacheErrorView` exists but is unreachable because the crash happens before it can be shown.

**Proposed Solution:**
```swift
init(inMemory: Bool = false) {
    do {
        self.container = try ModelContainer(for: schema, configurations: config)
    } catch {
        Logger.cache.error("Failed to create ModelContainer: \(error)")
        self.container = nil
        self.initializationError = error
    }
}
```
Then check `initializationError` in `LootListApp` to show `FatalCacheErrorView`.

---

### 1.6 `saveContext()` Silently Swallows Errors

**File & Line Range:** [CacheService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/CacheService.swift):58-65

**Category:** Bug  
**Severity:** 🔴 High

**Issue:** `saveContext()` catches errors and only logs them. Callers proceed as if the write succeeded, leading to data loss — the UI shows a state that was never actually persisted.

**Proposed Solution:** Rethrow the error so callers can react:
```swift
func saveContext() throws {
    do {
        try modelContext.save()
    } catch {
        Logger.cache.error("Failed to save context: \(error)")
        throw error
    }
}
```

---

### 1.7 CloudKit `try?` Silent Error Swallowing — Treats Network Failures as "Not Found"

**File & Line Range:** [CloudKitService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/CloudKitService.swift):250-254

**Category:** Bug  
**Severity:** 🔴 High

**Issue:** `if let existing = try? await targetDB.record(for: targetID)` swallows ALL errors. When the network is down, it assumes the record doesn't exist and creates a new one, causing a `serverRecordChanged` conflict on the next sync.

**Proposed Solution:**
```swift
let recordToSave: CKRecord
do {
    recordToSave = try await targetDB.record(for: targetID)
} catch let error as CKError where error.code == .unknownItem {
    recordToSave = CKRecord(recordType: T.recordType, recordID: targetID)
} catch {
    throw error // Propagate network errors
}
```

---

### 1.8 `SyncEngine.syncAll` — No Double-Invocation Guard

**File & Line Range:** [SyncEngine.swift](file:///Users/kupan787/opencode/LootList/Project/Services/SyncEngine.swift):45-120

**Category:** Bug  
**Severity:** 🔴 High

**Issue:** `syncAll()` can be called concurrently (app foreground + push notification arriving simultaneously). No guard prevents two full sync passes running in parallel, risking duplicate inserts and race conditions against the shared SwiftData context.

**Proposed Solution:**
```swift
private var isSyncing = false

func syncAll() async {
    guard !isSyncing else {
        Logger.sync.info("Sync already in progress, skipping")
        return
    }
    isSyncing = true
    defer { isSyncing = false }
    // ... existing sync logic
}
```

---

### 1.9 CloudKit Bool Extraction — `NSNumber` Bridge Failure

**File & Line Range:**
- [QuestTemplate.swift](file:///Users/kupan787/opencode/LootList/Project/Models/CloudKit/QuestTemplate.swift):79, 98
- [Profile.swift](file:///Users/kupan787/opencode/LootList/Project/Models/CloudKit/Profile.swift):92

**Category:** Bug  
**Severity:** 🟡 High

**Issue:** `(record["isAllOrNothing"] as? Bool) ?? false` — CloudKit bridges booleans via `NSNumber`. If the value comes back as `NSNumber`, `as? Bool` fails silently and defaults to `false`, causing all-or-nothing policies to silently revert to per-quest payout.

**Proposed Solution:**
```swift
// Safe Bool extraction from CKRecord
extension CKRecord {
    func bool(forKey key: String, default defaultValue: Bool = false) -> Bool {
        if let boolVal = self[key] as? Bool { return boolVal }
        if let numVal = self[key] as? NSNumber { return numVal.boolValue }
        return defaultValue
    }
}
```

---

### 1.10 `isDayCompleted` Ignores `targetCount` and `verificationStatus`

**File & Line Range:** [HeroDashboardViewModel.swift](file:///Users/kupan787/opencode/LootList/Project/ViewModels/HeroDashboardViewModel.swift):257-261

**Category:** Bug  
**Severity:** 🟡 High

**Issue:** A day is marked complete if a quest has *any* log entry (`logsByQuestRecordName[quest.recordName] != nil`). This ignores multi-completion quests (`targetCount > 1`) and doesn't filter out rejected logs. A rejected quest log still counts as "completed."

**Proposed Solution:**
```swift
func isDayCompleted(day: Date) -> Bool {
    let dayQuests = quests(for: day)
    return dayQuests.allSatisfy { quest in
        let approvedLogs = logs(for: quest).filter {
            $0.verificationStatusEnum != .rejected
        }
        return approvedLogs.count >= quest.targetCount
    }
}
```

---

### 1.11 Notifications Default to OFF on Fresh Installs

**File & Line Range:** [NotificationService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/NotificationService.swift):45-60

**Category:** Bug  
**Severity:** 🟡 Medium

**Issue:** `isNotificationEnabled(for:)` falls back to `UserDefaults.standard.bool(forKey:)` which returns `false` for missing keys. On a fresh install (before the first sync populates the cache), ALL notifications are silently disabled.

**Proposed Solution:**
```swift
// Distinguish "not set" from "explicitly false"
if let value = UserDefaults.standard.object(forKey: event.userDefaultsKey) as? Bool {
    return value
}
return true // Notifications enabled by default
```

---

### 1.12 N+1 Query Anti-Pattern — Sequential CloudKit Fetches in Loops

**File & Line Ranges:**
- [QuestService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/QuestService.swift):739-744
- [AchievementService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/AchievementService.swift):361-365

**Category:** Bug / Performance  
**Severity:** 🟡 Medium

**Issue:** Missing quest IDs are fetched from CloudKit sequentially inside `for` loops. On a cold cache, this triggers dozens of sequential network calls, causing massive UI stalls.

**Proposed Solution:** Batch the missing IDs and use a chunked query:
```swift
for chunk in missingIDs.chunked(into: 100) {
    let predicate = NSPredicate(format: "recordID IN %@", chunk)
    let fetched = try await cloudKit.query(Quest.self, predicate: predicate)
}
```

---

### 1.13 `NotificationSettingsView` — UserDefaults/CloudKit Sync Drift

**File & Line Range:** [NotificationSettingsView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Profile/NotificationSettingsView.swift):219-235

**Category:** Bug  
**Severity:** 🟡 Medium

**Issue:** `UserDefaults` is updated synchronously while `notificationService.updatePreference` runs in an async `Task`. If the network call fails, `UserDefaults` is permanently out of sync with CloudKit truth.

**Proposed Solution:**
```swift
set: { newValue in
    Task {
        do {
            try await notificationService.updatePreference(event: event, enabled: newValue)
            UserDefaults.standard.set(newValue, forKey: event.userDefaultsKey)
        } catch {
            // Revert: re-read from service
        }
    }
}
```

---

## 2. Architectural Improvements

Issues that affect maintainability, scalability, and developer ergonomics.

---

### 2.1 Test Mock Logic Mixed Into Production Code

**File & Line Range:** [CloudKitService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/CloudKitService.swift):129-132, 216-224, 304-309

**Category:** Architecture  
**Severity:** 🔴 High

**Issue:** `CloudKitService` checks `TestEnvironment.isRunningUnitOrUITests` in nearly every method to divert to a `mockRecords` dictionary. This violates separation of concerns, bloats the production binary, and is highly error-prone.

**Proposed Solution:** Extract `CloudKitService` behind a full protocol (not just `CloudKitServicing` for save/fetch). Provide a `MockCloudKitService` conformer for tests, eliminating all test branches from production code.

---

### 2.2 `SyncEngine.fetchAndCacheAllEntities` — 10 Concurrent CloudKit Queries

**File & Line Range:** [SyncEngine.swift](file:///Users/kupan787/opencode/LootList/Project/Services/SyncEngine.swift):85-94

**Category:** Architecture / Performance  
**Severity:** 🔴 High

**Issue:** Fires 10 concurrent `async let` CloudKit queries. CloudKit heavily throttles concurrent operations; this will likely trigger `CKError.limitExceeded` (Code 27) for users with large databases.

**Proposed Solution:** Use `TaskGroup` with bounded concurrency (2-3 concurrent fetches), or sequence them in priority order.

---

### 2.3 `FamilyDashboardViewModel.rebuildLists` — O(N²) on @MainActor

**File & Line Range:** [FamilyDashboardViewModel.swift](file:///Users/kupan787/opencode/LootList/Project/ViewModels/FamilyDashboardViewModel.swift):71-186

**Category:** Architecture / Performance  
**Severity:** 🟡 High

**Issue:** Heavy O(N²) filtering, mapping, and dictionary creation on SwiftData arrays runs directly on `@MainActor`. Called on every `.onChange(of: cachedItems)`, this blocks the main thread and causes frame drops with large families.

**Proposed Solution:** Push derivation to a background `Task` or a stateless domain service (`FamilySummaryBuilder`). The ViewModel awaits the final result.

---

### 2.4 `QuestManagerViewModel.fetchPendingQuestLogs` — Unbounded Memory Load

**File & Line Range:** [QuestManagerViewModel.swift](file:///Users/kupan787/opencode/LootList/Project/ViewModels/QuestManagerViewModel.swift):224-247

**Category:** Architecture / Performance  
**Severity:** 🟡 High

**Issue:** Pulls ALL completions for the entire family into memory and manually loops to find `.pending` statuses. As log history grows, this becomes an extreme memory bottleneck.

**Proposed Solution:** Use a SwiftData/CloudKit predicate to query for `verificationStatus == .pending` at the database level.

---

### 2.5 `AchievementService.checkAndUnlockAchievements` — Unbounded Data Load

**File & Line Range:** [AchievementService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/AchievementService.swift):85-130

**Category:** Architecture / Performance  
**Severity:** 🟡 Medium

**Issue:** Fetches ALL completions AND ALL ledger entries for the family to evaluate achievement criteria. For families with months of activity, this is an unbounded memory load.

**Proposed Solution:** Use aggregate counts from the cache or add date-range filtering for time-bounded achievements.

---

### 2.6 `LootListApp.init` — `@State` Initialization Anti-Pattern

**File & Line Range:** [LootListApp.swift](file:///Users/kupan787/opencode/LootList/Project/App/LootListApp.swift):110-121

**Category:** Architecture  
**Severity:** 🟡 Medium

**Issue:** Initializing `@State` via `_property = State(initialValue:)` in `init` is a known SwiftUI anti-pattern. If `init` runs again, new instances are created but the old `@State` storage persists, causing a dependency graph mismatch.

**Proposed Solution:** Extract dependency wiring into an `@Observable final class AppEnvironment`.

---

### 2.7 `CloudKitServicing` Protocol Misplaced

**File & Line Range:** [XPService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/XPService.swift):25-45

**Category:** Architecture  
**Severity:** 🟡 Low

**Issue:** The only extracted service protocol (`CloudKitServicing`) is declared inside `XPService.swift` rather than in its own file. This makes it non-discoverable for other consumers.

**Proposed Solution:** Move to `Services/CloudKitServicing.swift`.

---

### 2.8 SwiftData Indexes — Single-Column Instead of Composite

**File & Line Range:** Multiple `*Cache.swift` files (e.g., [QuestCache.swift](file:///Users/kupan787/opencode/LootList/Project/Models/Local/QuestCache.swift):13)

**Category:** Architecture / Performance  
**Severity:** 🟡 Medium

**Issue:** `#Index<QuestCache>([\.familyRecordName], [\.assigneeRecordName], [\.weekOf])` creates three independent single-column indexes. Queries filtering by all three dimensions won't benefit from a composite index.

**Proposed Solution:**
```swift
#Index<QuestCache>([\.familyRecordName, \.assigneeRecordName, \.weekOf])
```

---

### 2.9 Role-Gating Not Formalized

**File & Line Range:** [FamilyService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/FamilyService.swift):45-52

**Category:** Architecture  
**Severity:** 🟡 Medium

**Issue:** `guard appState.isZoneOwner else { return }` is scattered across multiple methods. A new method could easily omit the guard, creating a privilege escalation bug.

**Proposed Solution:**
```swift
private func requireOwner() throws {
    guard appState.isZoneOwner else {
        throw FamilyServiceError.notOwner
    }
}
// Usage: try requireOwner() // at top of every mutation
```

---

### 2.10 `AppState.restoreSession` — Silent Offline Fallback

**File & Line Range:** [AppState.swift](file:///Users/kupan787/opencode/LootList/Project/App/AppState.swift):95-140

**Category:** Architecture  
**Severity:** 🟡 Medium

**Issue:** When CloudKit is unreachable, falls back to cache. If the cache is also empty/corrupted, the user is silently authenticated with nil/incorrect data.

**Proposed Solution:** Add an explicit `offlineWithEmptyCache` error state that the UI can handle gracefully.

---

### 2.11 Cross-Service Coupling for Date Math

**File & Line Range:** [FamilyService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/FamilyService.swift):685-696

**Category:** Architecture  
**Severity:** 🟡 Low

**Issue:** `unassignActiveQuests` fetches `TreasuryService.mondayOfWeek` and `QuestService.mondayOfWeek` to assert they match. This couples sibling services unnecessarily.

**Proposed Solution:** Call `WeekMath.mondayOfWeek(for: Date())` directly.

---

### 2.12 `GoldCalculation` Uses `Double` for Currency

**File & Line Range:** [GoldCalculation.swift](file:///Users/kupan787/opencode/LootList/Project/Utilities/GoldCalculation.swift):20-35

**Category:** Architecture  
**Severity:** 🟡 Low

**Issue:** Using `Double` for financial calculations accumulates floating-point errors over time.

**Proposed Solution:** Migrate to `Decimal` for all currency computations.

---

## 3. DRY & Refactoring Quick Wins

Duplicated code and patterns that should be consolidated.

---

### 3.1 Optimistic Write-Through Boilerplate — ~500 Lines of Copy-Paste

**Files:**
- [QuestService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/QuestService.swift) (~4 methods)
- [TreasuryService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/TreasuryService.swift) (~2 methods)
- [FamilyService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/FamilyService.swift) (~7 methods)
- [SpendingService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/SpendingService.swift) (~1 method)
- [XPService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/XPService.swift) (~1 method)

**Category:** DRY  
**Severity:** 🔴 High

**Issue:** Every mutation method copies ~15-20 lines of identical recovery logic: capture `preMutationChangeTag`, call `detectConcurrentEdit`, invalidate/restore snapshots, present toast. This is the single largest duplication in the codebase.

**Proposed Solution:**
```swift
struct OptimisticWriter {
    static func perform<T: CloudKitRecord>(
        snapshot: T?,
        optimisticWrite: () async throws -> Void,
        cloudKitSave: () async throws -> T,
        rollback: (T?) async throws -> Void,
        detectEdit: () async -> Bool,
        toastManager: ToastManager?
    ) async throws -> T {
        // Centralized snapshot/save/rollback/detect logic
    }
}
```

---

### 3.2 `BackgroundCacheActor` — ~10 Identical `batchUpsert*` Methods

**File & Line Range:** [BackgroundCacheActor.swift](file:///Users/kupan787/opencode/LootList/Project/Services/BackgroundCacheActor.swift):29-458

**Category:** DRY  
**Severity:** 🟡 High

**Issue:** ~10 `batchUpsert*` methods follow the exact same pattern (fetch by recordName → update or insert → save). Hundreds of lines of near-identical code.

**Proposed Solution:**
```swift
protocol CacheMergeable: PersistentModel {
    var recordName: String { get }
    func merge(from source: Self)
}

func batchUpsert<T: CacheMergeable>(_ items: [T]) throws { ... }
```

---

### 3.3 `CacheService+Fetches` — ~12 Identical Fetch Methods

**File & Line Range:** [CacheService+Fetches.swift](file:///Users/kupan787/opencode/LootList/Project/Services/CacheService+Fetches.swift):1-250

**Category:** DRY  
**Severity:** 🟡 Medium

**Issue:** Every fetch method repeats: build predicate → `FetchDescriptor` → `modelContext.fetch` → catch/log/return-empty.

**Proposed Solution:**
```swift
func fetch<T: PersistentModel>(
    _ type: T.Type,
    predicate: Predicate<T>,
    sorts: [SortDescriptor<T>] = []
) -> [T]
```

---

### 3.4 `CacheService+Invalidation` — ~10 Identical Delete Methods

**File & Line Range:** [CacheService+Invalidation.swift](file:///Users/kupan787/opencode/LootList/Project/Services/CacheService+Invalidation.swift):1-180

**Category:** DRY  
**Severity:** 🟡 Medium

**Issue:** Every `invalidate*` method: fetch by recordName → delete → saveContext(). Repeated ~10 times.

**Proposed Solution:**
```swift
func invalidate<T: PersistentModel>(_ type: T.Type, recordName: String) where T: FamilyScopedCache
```

---

### 3.5 Gold Calculation Loop Duplicated Across 3 ViewModels

**Files:**
- [FamilyDashboardViewModel.swift](file:///Users/kupan787/opencode/LootList/Project/ViewModels/FamilyDashboardViewModel.swift):117-123
- [HeroDashboardViewModel.swift](file:///Users/kupan787/opencode/LootList/Project/ViewModels/HeroDashboardViewModel.swift):162-190
- [TreasuryViewModel.swift](file:///Users/kupan787/opencode/LootList/Project/ViewModels/TreasuryViewModel.swift):63-70

**Category:** DRY  
**Severity:** 🟡 Medium

**Issue:** The gold aggregation loop using `GoldCalculation.creditAsDouble` is copy-pasted across three ViewModels.

**Proposed Solution:**
```swift
extension GoldCalculation {
    static func totalGold(
        for quests: [QuestCache],
        logs: [QuestCompletionCache]
    ) -> Double { ... }
}
```

---

### 3.6 CloudKit Model `init(record:)` Boilerplate

**Files:** All 10 `Models/CloudKit/*.swift` files

**Category:** DRY  
**Severity:** 🟡 Medium

**Issue:** Each model manually extracts fields with `record["key"] as? Type ?? default`, repeating the same guard-and-throw pattern.

**Proposed Solution:**
```swift
extension CKRecord {
    func extract<T>(_ key: String) throws -> T {
        guard let value = self[key] as? T else {
            throw CKDecodingError.missingField(key)
        }
        return value
    }
}
// Usage: self.name = try record.extract("name")
```

---

### 3.7 `CacheConversions.swift` — Fragile Field-by-Field Mapping

**File & Line Range:** [CacheConversions.swift](file:///Users/kupan787/opencode/LootList/Project/Services/CacheConversions.swift):1-350

**Category:** DRY  
**Severity:** 🟡 Medium

**Issue:** ~12 pairs of bidirectional conversion functions manually map every field. Adding a field to a model requires updating multiple conversion points.

**Proposed Solution:** Move conversions to `init(cache:)` initializers on domain models and `init(from:)` on cache models, co-locating conversion logic with the types.

---

### 3.8 Enum Convenience Getters on Cache Models

**Files:** 8+ `*Cache.swift` files (e.g., [QuestCache.swift](file:///Users/kupan787/opencode/LootList/Project/Models/Local/QuestCache.swift):45-70)

**Category:** DRY  
**Severity:** 🟡 Low

**Issue:** Every cache model stores enums as `String` and provides computed getters like `var approvalModeEnum: ApprovalMode? { ApprovalMode(rawValue: approvalMode) }`. Repeated across 8+ files.

**Proposed Solution:** Consider a property wrapper or Swift macro to auto-generate the backing store and computed accessor.

---

### 3.9 Image Resizing Logic in Views

**File & Line Range:** [ProfileView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Profile/ProfileView.swift):681-696

**Category:** DRY  
**Severity:** 🟡 Low

**Issue:** Image resizing via `UIGraphicsImageRenderer` is placed directly in the view's `.onChange` modifier.

**Proposed Solution:** Extract to `AvatarService.resizeImage(data:maxDimension:) -> Data?`.

---

## 4. Swift Modernization Opportunities

Language and framework idiom upgrades.

---

### 4.1 Sequential `await` Where `async let` Applies

**File & Line Range:** [AppState.swift](file:///Users/kupan787/opencode/LootList/Project/App/AppState.swift):122-123

**Category:** Modernity  
**Severity:** 🟡 Low

**Issue:** `fetchProfile` and `fetchFamily` are awaited sequentially but have no data dependency.

**Proposed Solution:**
```swift
async let fetchedProfile = cloudKit.fetch(Profile.self, id: profileID, using: db)
async let fetchedFamily = cloudKit.fetch(Family.self, id: familyID, using: db)
let (profile, family) = try await (fetchedProfile, fetchedFamily)
```

---

### 4.2 `Task.sleep(nanoseconds:)` Deprecated

**File & Line Range:** [AppDelegate.swift](file:///Users/kupan787/opencode/LootList/Project/App/AppDelegate.swift):42

**Category:** Modernity  
**Severity:** 🟡 Low

**Issue:** `Task.sleep(nanoseconds:)` is deprecated in favor of `Clock`-based sleep.

**Proposed Solution:**
```swift
try? await Task.sleep(for: .seconds(25))
```

---

### 4.3 `ToastManager` Uses UIKit `Timer`

**File & Line Range:** [ToastManager.swift](file:///Users/kupan787/opencode/LootList/Project/Services/ToastManager.swift):30-45

**Category:** Modernity  
**Severity:** 🟡 Low

**Issue:** Uses `Timer.scheduledTimer` for auto-dismissal — a UIKit-era pattern.

**Proposed Solution:** Use `Task.sleep(for:)` in a structured `Task` for native Swift concurrency.

---

### 4.4 `SyncEngine.syncTask` — Missing Cancellation in `deinit`

**File & Line Range:** [SyncEngine.swift](file:///Users/kupan787/opencode/LootList/Project/Services/SyncEngine.swift):385-411

**Category:** Modernity / Bug  
**Severity:** 🟡 Low

**Issue:** `listenToPushNotifications()` creates an unstructured `Task` stored in `syncTask`, but there's no `deinit` cancellation.

**Proposed Solution:**
```swift
deinit {
    syncTask?.cancel()
}
```

---

### 4.5 Async Re-Entrancy Risk in OnboardingViewModel

**File & Line Range:** [OnboardingViewModel.swift](file:///Users/kupan787/opencode/LootList/Project/ViewModels/OnboardingViewModel.swift):120, 174

**Category:** Modernity  
**Severity:** 🟡 Low

**Issue:** `createFamily` and `joinFamily` set `isLoading = true` but don't guard against double-invocation.

**Proposed Solution:**
```swift
func createFamily() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    // ...
}
```

---

## Summary Dashboard

| Priority | Count | Examples |
|:---------|:-----:|:---------|
| 🔴 **Critical** | 4 | allOrNothing payout bug (×2), non-atomic QuestCompletion+XP, non-atomic weekly payout |
| 🔴 **High** | 6 | Force `try!`, silent saveContext, silent `try?`, double-sync race, test mock coupling, optimistic boilerplate DRY |
| 🟡 **Medium** | 14 | Bool extraction, isDayCompleted logic, notifications default OFF, N+1 queries, unbounded memory loads, SwiftData indexes |
| 🟡 **Low** | 10 | Sequential await, deprecated API, Timer pattern, enum getters DRY, protocol placement |

> **Recommended implementation order:**
> 1. Fix `allOrNothing` payout logic across all 3 ViewModels (§1.1, §1.2)
> 2. Add atomicity to `processWeeklyPayout` and `completeQuest` (§1.3, §1.4)
> 3. Replace force `try!` and silent error swallowing in CacheService (§1.5, §1.6)
> 4. Fix CloudKit `try?` silent swallowing (§1.7)
> 5. Add sync guard and fix Bool extraction (§1.8, §1.9)
> 6. Extract optimistic write-through helper to collapse ~500 lines of duplication (§3.1)
> 7. Address architectural performance issues (§2.2, §2.3, §2.4, §2.8)
