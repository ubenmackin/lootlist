# ARCHITECTURE.md — Loot List (Allowance Tracker)

## Project Soul

Loot List is a family chore and allowance tracker for iOS, themed as a fantasy RPG. Parents ("Guild Masters") assign quests to their kids ("Heroes"), who complete them to earn money (allowance). The app uses iCloud sync so the entire family sees the same data in real time, with a local SwiftData cache so the app remains usable offline.

**Why this architecture:**
- **CloudKit is the only viable native sync mechanism for a family app on Apple's ecosystem.** It provides real-time push updates, offline queueing, and zero server cost. The Guild Master owns the family data in their private database and shares it with Heroes via `CKShare`; Heroes read/write through the shared database after accepting the invite.
- **A local SwiftData cache sits in front of CloudKit for reads.** CloudKit fetches are async and network-bound; the cache lets the UI hydrate instantly and lets the app launch offline. CloudKit remains the source of truth; the cache is a derived, write-through read store.
- **SwiftUI + MVVM** is the modern Apple standard. Combined with the iOS 26 SDK, we use the latest APIs and patterns (`@Observable`, `NavigationStack`, SF Symbols 6+).
- **Protocol-based service layer** allows us to swap implementations (e.g., manual ledger → FinanceKit) without touching views or models. The primary CloudKit seam is `CloudKitServiceProtocol` (a `@MainActor`, `AnyObject & Sendable` protocol in `Project/Services/CloudKitServiceProtocol.swift`) declaring the full surface the service layer consumes — database selection, zone management, record CRUD, zone-change fetches, share lifecycle, abandoned-zone processing. Every service (`QuestService`, `TreasuryService`, `FamilyService`, `NotificationService`, `SyncEngine`, `SpendingService`) and `AppState` depend on `any CloudKitServiceProtocol`; `CloudKitService` (production) and `MockCloudKitService` (unit tests) are its conformers. `CloudKitServicing` remains a narrower `@MainActor` seam defined alongside `XPService` that abstracts `CloudKitService.save/fetch` specifically for `XPService`'s unit tests.
- **RPG theming is not cosmetic — it's core.** Every user-facing term, every screen, every notification uses the game vocabulary — with one deliberate exception: **money**. Allowance is real local currency and is always displayed in the user's region currency (§7.1), never as a fictional in-game currency. This split (game vocabulary for engagement, real-money presentation for financial literacy) drives the product.

---

## Tech Stack

- **Language:** Swift 6.0 (strict concurrency)
- **UI:** SwiftUI (iOS 26+)
- **Persistence:** CloudKit (source of truth) + SwiftData (local read cache / offline fallback)
- **Sync:** CloudKit `CKShare` (owner → private DB, participant → shared DB), `CKSubscription` for live push
- **Build:** XcodeGen (`project.yml` → `LootList.xcodeproj`)
- **Architecture:** MVVM with a protocol-based Service layer
- **Min Target:** iOS 26.0
- **Container:** `iCloud.com.volcrypt.lootlist`

---

## Architectural Decisions

### 1. CloudKit Ownership Model (Private vs Shared Database)

The family is a CloudKit **custom zone**. The database a participant reads from depends on their role — this is the core distinction the app is built around.

- **Guild Master (owner):** Creates the `Family` record in their **`privateCloudDatabase`**, then shares the zone via `CKShare`. The owner always operates on `privateDatabase` for that family.
- **Hero (participant):** Accepts the `CKShare` invitation, after which the family zone becomes visible in their **`sharedCloudDatabase`**. All their reads/writes go to `sharedDatabase`.
- **`CloudKitService` encodes this split explicitly:** `database(isOwner:)`, `activeFamilyZoneID`, `activeIsOwner`, `activeFamilyDatabase`, `resolvedZoneID`, plus `privateDatabase` / `sharedDatabase` accessors. `AppState.isZoneOwner` drives which DB is selected.
- **Real-time sync:** `CKSubscription` per zone pushes changes to all devices; `AppSyncCoordinator` fans these events out to subscribers (see §2).
- **Offline:** CloudKit queues local changes and syncs when online; the local cache (§2) keeps reads working with no network.
- **Share lifecycle:** `createShare` / `fetchOrCreateShareURL` / `acceptShare`; incoming share URLs are handled via `.onOpenURL` in `LootListApp` and surfaced to the onboarding view model as `pendingShareMetadata`.
- **Zone cleanup:** Rejected/abandoned family zones are tracked in `AppState.abandonedZoneIDs` (persisted in UserDefaults) and drained by `CloudKitService.processAbandonedZonesQueue` at launch.

> ⚠ Do **not** treat the family data as "all in the shared database." Every CloudKit call must go through `CloudKitService.database(isOwner:)` so it targets the correct database for the current user.

### 2. Two-Tier Persistence: CloudKit (truth) + SwiftData (cache)

CloudKit is the source of truth. A local SwiftData cache mirrors CloudKit records so the UI can read synchronously (0ms rendering) and the app operates seamlessly offline.

**Layer responsibilities:**
- **`Models/Local/*Cache`** — one SwiftData `@Model` class per CloudKit record type, each shaped by an invariant contract, not an ad-hoc table: `@Attribute(.unique) var recordName: String` (the CloudKit record name), `var familyRecordName: String` (scopes every cached record to a family), and `#Index` macro annotations on high-frequency query parameters (`familyRecordName`, `profileRecordName`, `assigneeRecordName`, `weekOf`, `date`, `iCloudUserRecordName`, …) for sub-millisecond lookups. Enum convenience getters (`approvalModeEnum`, `rarityEnum`, `scheduleTypeEnum`, `verificationStatusEnum`, `roleEnum`, `payoutPolicyEnum`, `avatarClassEnum`, `statusEnum`, `categoryEnum`, `requirementTypeEnum`) give views/ViewModels clean, typed access. The SwiftData `VersionedSchema` for the cache is the `LootListSchemaV1` → `LootListSchemaV2` → `LootListSchemaV3` → `LootListSchemaV4` chain (1.0.0 → 2.0.0 → 3.0.0 → 4.0.0), and the active container schema is V4; `LootListMigrationPlan` wires a `.lightweight` stage for each step — V1→V2 adds `QuestCache.xpBanked` + `QuestCompletionCache.xpCredited`, V2→V3 adds `FamilyCache.payoutDay` (non-optional `String` defaulting to `"sunday"`) + `ProfileCache.payoutDay` (optional `String`), V3→V4 adds `FamilyCache.creatorUserRecordName` (optional `String`) — see §11. Non-schema data backfills are handled separately by `DataMigrationsCoordinator` (§11).
- **`CacheService`** — `@MainActor` local store wrapping a SwiftData `ModelContainer`. Uses OS logger logging and centralized `saveContext()` / `withBatch` error-handling. Family-scoped fetches go through a generic `familyScopedFetch<T: FamilyScopedCache>` helper constrained to the `FamilyScopedCache` protocol (which mandates the `familyRecordName` field); per-record `invalidate*` helpers power the snapshot/rollback path that removes phantom optimistic rows.
- **`BackgroundCacheActor`** — an `actor` executing on a dedicated background context with `autosaveEnabled = false`. Performs batch upserts and missing-record purges off the main thread so full-sync operations never cause frame drops or UI jank. **Every `purgeMissing*` is family-scoped**: each wrapper validates a concrete `familyRecordName` and short-circuits on a nil/empty scope, so a sync can never delete another family's cached rows; `FamilyCache` is exempt as the root record and is always purged globally. **Batch upserts respect the in-flight mutation registry** (owned by `CacheService`, injected at construction): rows whose `recordName` is currently under an optimistic write are skipped — the set is snapshotted once per batch, one actor hop — so a background sync cannot clobber an in-flight mutation with stale server data; the author's post-save re-upsert reconciles the row.
- **`SyncEngine`** — orchestrates pulling CloudKit changes into the cache. Full sync is scoped to the active family zone: `syncAllForActiveZone()` is the launch bootstrap (the CloudKit zone is named after the Family record, so the resolved zone's name is the concrete family scope), and `syncAll(familyRecordName:)` covers an explicit scope; token-based incremental sync (`incrementalSync`) uses `CKFetchRecordZoneChangesOperation` with per-zone, per-database-scope `CKServerChangeToken`s persisted in UserDefaults. At the END of each successful `batchUpsert*` + `purgeMissing*` pass it stamps the per-family-per-type freshness watermark for that type (see below), and every pass posts a `.syncDidComplete` notification carrying a terminal `SyncOutcome` (`.changed` / `.noChange` / `.failed`) for background-fetch coordination (see §Sync & Conflict).
- **`AppSyncCoordinator`** — registers `CKSubscription`s per zone and fans `CKNotification`s out to subscribers via `AsyncStream<SyncEvent>` (`recordChanged(subscriptionID)`, `shareAccepted(shareID)`, `zoneReset`).
- **Cache freshness watermark (per-family-per-type)** — `CacheService` exposes `isCacheFresh(familyRecordName:type:)` over a UserDefaults stamp keyed `cache_fresh_<familyRecordName>_<type>` (a `Date` written by `markCacheFresh`, kept in UserDefaults rather than SwiftData so stamps survive cache purges and are cheap to read on every gate). Only `SyncEngine` writes stamps, and only after a `batchUpsert*` + `purgeMissing*` pass completes without throwing — an empty result set still stamps, because an empty zone IS a complete sync of that type. Incremental passes re-stamp only the types actually touched by the delta, and only on the final `moreComing == false` page, so an incomplete intermediate page is never served. **Read-first gate semantics:** the services (`QuestService`, `FamilyService`, `TreasuryService`, `AchievementService`, `NotificationService`, `ManualSpendingService`) serve the cache only when it is **fresh AND non-empty**; an absent stamp (never fully synced), a stamp cleared by `clearAll()` / `purgeFamily(recordName:)`, or an empty result falls through to a single CloudKit query that write-throughs the cache and returns the fetched result. On a cache-hit path no ad-hoc CloudKit refresh is issued — background updates flow through `SyncEngine`'s push-driven incremental pipeline, which keeps the stamp valid.
- **`CacheConversions.swift`** — free functions and extension getters bridging CloudKit domain models, SwiftData `*Cache` entities, and SwiftUI presentation enums.
- **`CachedRecordType` (typed delete path)** — a `String, CaseIterable, Sendable` enum with one case per local SwiftData cache type. `BackgroundCacheActor.deleteRecord(recordName:type:)` takes the typed enum rather than a raw `CKRecord.RecordType` string, and raw CKRecordType strings are resolved through `CachedRecordType.recordType(for:) -> CachedRecordType?`. This eliminates the Swift class-name ↔ CKRecordType mismatch class of bugs — the only entity whose Swift class name diverges from its CKRecordType is `QuestCompletion` (`recordType == "QuestLog"`), and the resolver captures that divergence in exactly one place (each model's `Type.recordType` constant). Unknown recordTypes return `nil` so `SyncEngine.incrementalSync` logs a warning and skips rather than crashing.

#### UserDefaults Policy

UserDefaults is **device-local** and never participates in CloudKit sync. It is the right store for exactly three categories of state:

1. **Device-local session and sync-cursor state** — the active-session record (`AppState` profile/family/zone/isOwner in `UserDefaults.standard`), the abandoned-zone queue (`AppState.abandonedZoneIDs`), `CKServerChangeToken` cursors per zone and database scope (`SyncEngine.tokenKey(for:isShared:)`), and `DataMigrationsCoordinator` migration bookkeeping. Each device tracks its own position; cross-device cursor state is not meaningful.
2. **Per-device read-gate metadata** — the cache-freshness watermarks `cache_fresh_<familyRecordName>_<type>` written by `SyncEngine` and read by the services (see the *Cache freshness watermark* bullet above). Kept in UserDefaults rather than SwiftData so stamps survive cache purges and are cheap to read on every gate.
3. **Strictly-subordinate fallbacks to a CloudKit-backed source of truth** — read **only** when the cache is unfresh (brand-new install before the first `syncAllForActiveZone`). The `masterNotificationsEnabled` + per-event `UserDefaults` mirrors that back `NotificationPreference` (§10) are the sanctioned example: the CloudKit record + SwiftData cache is the source of truth, and the mirror is consulted solely on the first-launch cold path.

**Forbidden:** UserDefaults is **never** appropriate for authoritative cross-device domain data — counters, balances, credit totals, reward caps, or any value that two devices could both mint or mutate. Such values must persist on CloudKit records mirrored into SwiftData.

**Enforcement — the XP-credit ledger.** The per-quest XP-credit ledger is the concrete case this rule exists to prevent from recurring. It previously lived in a `UserDefaults` key (`XPCreditLedger`) — cross-device economic state in device-local storage — so two devices completing the same quest concurrently could each mint the full XP bounty beyond the quest's reward. That ledger was **removed** and replaced by a CloudKit-authoritative scheme mirrored into SwiftData via the `LootListSchemaV2` lightweight migration:

- `Quest.xpBanked` — a **monotonic per-quest banked total** on the CloudKit `Quest` record. The reward step compare-and-swaps this cap serialized by CloudKit's change-tag (`detectConcurrentEdit`, §Conflict), so the banked total can never exceed the quest's XP bounty regardless of how many devices race.
- `QuestCompletion.xpCredited` — an optional `Int` on the CloudKit `QuestCompletion` record serving as a **per-record idempotency marker**. A completion whose `xpCredited` is already non-nil is never re-rewarded.

Both fields are mirrored as SwiftData cache attributes (`QuestCache.xpBanked`, `QuestCompletionCache.xpCredited`) for synchronous UI reads; the CloudKit records remain the source of truth. No UserDefaults XP ledger exists anywhere in the app. When adding any new economic counter (cap, balance, total), persist it on the CloudKit record first and mirror it into the cache — never into UserDefaults.

**View/ViewModel Pipeline (Zero-Latency Rendering):**
- **SwiftUI Views** declare `@Query` macros targeting `*Cache` models.
- On launch or model change, `.onChange(of: cachedItems)` passes `*Cache` arrays directly to `viewModel.rebuildLists(...)`.
- **ViewModels operate directly on `*Cache` models** to calculate derived state (`HeroSummary`, active/missed quests, streaks, balances, payouts) without converting to wire types (`Quest`, `Profile`, `LedgerEntry`). ViewModels avoid executing duplicate network fetches inside `load()` / `refresh()`.
- When navigating to single-entity detail views (e.g. `QuestDetailView`), `quest.toQuest(zoneID:)` converts the model on-demand for full mutation support.

**Optimistic Mutations with Snapshot Rollback:**
- All mutation methods in `QuestService`, `TreasuryService`, `AchievementService`, `ManualSpendingService`, and `FamilyService` write changes directly to SwiftData first for instant UI response (0ms delay).
- A snapshot of the original local state is held prior to the CloudKit save operation. If the network call fails, the snapshot is restored immediately to local SwiftData, ensuring strict consistency. For brand-new records that have no prior snapshot, the optimistically-inserted row is **invalidated** rather than restored, so the UI never shows a phantom CloudKit never accepted.

**At launch (`LootListApp` `.task`):**
1. `checkCloudKitAvailability()` (account status)
2. `processAbandonedZonesQueue`
3. `appState.restoreSession`
4. `syncEngine?.syncAllForActiveZone()` — hydrate the cache from CloudKit off main thread via `BackgroundCacheActor` (scoped to the resolved family zone)
5. `appSyncCoordinator.registerSubscriptions(for:in:)` — live push
6. `dataMigrationsCoordinator.runPendingMigrations()`

**In tests:** `CacheService(inMemory: true)` is used (`TestEnvironment.isRunningUnitOrUITests`), and `SampleData.populate(cloudKit:cacheService:)` seeds both layers.

### 3. SpendingService (Manual today; FinanceKit V2 planned)

`protocol SpendingService` (`@MainActor`, `Sendable`) lives in `Project/Services/SpendingService.swift`, with `ManualSpendingService` as its sole conformer. The protocol abstracts `fetchTransactions(for:in:)`, `isAvailable()`, `logManual(...)`, and `delete(_:)`; its protocol extension defaults the mutation methods to `SpendingServiceError.unsupported` so a read-only provider can skip them. Views (`LootListApp`, `TabBarView`) currently depend on `ManualSpendingService` directly. A `FinanceKitSpendingService` (pulling from Apple Card via FinanceKit) remains the planned V2 conformer; the protocol is the seam that makes the manual → FinanceKit swap a drop-in replacement with no UI changes.

### 4. Quest Approval (Configurable Per Quest)

```swift
enum ApprovalMode: String, Codable {
    case autoApprove      // Hero marks done → done (VerificationStatus.autoApproved)
    case parentVerify     // Hero marks done → pending → parent approves/rejects
}

enum VerificationStatus: String, Codable {
    case autoApproved
    case pending
    case verified
    case rejected
}
```

- Set per `QuestTemplate` or overridden per `Quest`.
- Default: `autoApprove`.
- `QuestCompletion` carries `verificationStatus`, `verifiedBy`, `verifiedDate`.
- Parent notifications fire for `pending` verifications.

### 5. Payout Policy

```swift
enum PayoutPolicy: String, Codable {
    case perQuest        // Pay Per Quest (Standard)
    case allOrNothing   // All-or-Nothing (Strict 100% weekly completion required)
    case realTime        // Real-Time (Instant Settlement)
}
```

- Lives on **`Family`** (family-wide default) **and** on **`Profile`** (per-hero override).
- `FamilyService` exposes `updatePayoutPolicy` (family) and `updateProfilePayoutPolicy` (per-hero).
- `allOrNothing` means the hero earns the week's money **only if** 100% of assigned quests are completed; otherwise the period pays nothing.
- `realTime` means each quest completion is settled immediately: `QuestService.applyReward` calls `TreasuryService.processRealTimeSettlement` when the hero's `payoutPolicy == .realTime`. Settlement credits the allowance period's totals (`totalEarned` / `questsCompleted`) and `paidAmount` **without closing the period** — the period's `status` is left untouched so it stays open; closing happens via `runPayout`.
- **(Half-open `[start, end)` week ranges)** Every "this week" boundary is routed through `WeekMath.weekRange(starting:) -> Range<Date>`, which produces a HALF-OPEN range whose upper bound is *exclusive* (`end == start + secondsInWeek`). `QuestService`, `TreasuryService`, `CacheService.fetchQuests(family:weekInRange:)`, and `FamilyDashboardViewModel` all share this single definition via `WeekMath` (which also owns `mondayOfWeek(for:)` / `weekOf(date:payoutDay:)` / `startOfWeek(for:payoutDay:)`, consolidated from the prior QuestService ↔ TreasuryService duplication). **The week cycle is payout-day-aware:** `WeekMath.startOfWeek(for:payoutDay:)` anchors the cycle on the configured payout day (with `payoutDay == .sunday` the cycle starts the following Monday), and the effective payout day resolves as **profile override → family → `.sunday` fallback** (`QuestService.effectivePayoutDay(for:)`; `TreasuryService` mirrors it via `profile.payoutDay ?? family.payoutDay` / `profile.payoutDay ?? .sunday`), so reads bucket by the same cycle the stored `weekOf` values were normalized to. This removes the prior divergence where `TreasuryService` used a CLOSED `DateInterval` (`end = start + secondsInWeek - 1`) while `QuestService` used a half-open range — a divergence that could disagree by exactly one quest on edge weeks (a completion timestamped Sunday 23:59 → Monday 00:00 falling on the seam). With `end` EXCLUSIVE, a `Date` equal to `end` belongs to the *following* week on both sides.

### 6. Quest Rarity

```swift
enum QuestRarity: String, CaseIterable, Codable {
    case common, rare, epic, legendary
}
```

Each rarity maps to an XP reward (`AppConstants.Rarity.*XP`), a color, and an SF Symbol icon. `Quest.rarity` is **derived**, not stored — it is computed from the quest's XP via `QuestRarity.from(xp:)`. Rarity is RPG-thematic but also structural — it drives the reward/color/icon shown across the UI.

### 7. RPG Terminology (User-Facing)

| Concept | User-Facing Term |
|---|---|
| Chores | Quests |
| Completed | Completed |
| Allowance | Money |
| Ledger | Scroll of Spending |
| Streak | Combo Streak 🔥 |
| Bonus | Loot Drop 🎁 |
| Milestones | Trophies 🏆 |
| Trophy Room | Hall of Heroes 🏛️ |
| Parent (Owner) | Guild Master |
| Parent (Admin) | Ranger |
| Kids | Heroes |
| Profiles | Characters |
| Weekly payout | Sunday Loot Day |

#### 7.1 Money Display (Locale-Aware Currency)

Money is **real local currency**, not a fictional in-game currency. This drives two cross-cutting constraints:

- **One canonical formatter.** Every user-facing money amount — badges, balances, payouts, breakdowns, notification bodies, trophy requirement text — must render through `CurrencyFormatter` (`Project/Views/Shared/NumberFormatter+Gold.swift`; the file name is legacy), which resolves the symbol, grouping, and decimal separators from `Locale.current` at call time (`$10.00`, `£10.00`, `10,00 €`, `¥1,000`). Never hardcode a currency symbol (`"$"`) and never format money with a bare `String(format: "%.2f", …)`. `TreasuryView`'s `GoldFormat` (signed `+`/`−` ledger variants) is a thin wrapper on top of it.
- **"Money" is the universal noun.** "Gold" is retired from user-facing copy. Stat headers use "Earned"/"Earnings" ("Earned This Week", "Total Earned"); form labels use "Reward"/"Amount" ("Default Reward", "Reward Override"). "\(x) gold" suffixes are banned. Currency-neutral SF Symbol `banknote` replaces coin/currency-specific icons (`circle.hexagongrid.fill`, `dollarsign.circle.fill`) in money-display and money-action contexts (never 💰/💵 emoji — they render a literal dollar sign on Apple platforms). Trophy names "Fortune Hoarder"/"Fortune Magnate" (formerly "Gold Hoarder"/"Gold Magnate").
- **Internal identifiers keep the `gold` prefix** (`goldReward`, `GoldCalculation`, `GoldFormat`, `Color.gold`, `AchievementCategory.gold`, `AchievementRequirement.gold100/gold500`, `NotificationEventType.goldEarned`) — they are invisible to users and are decoupled from user-facing terms by this table. Do not rename them; renaming shipped CloudKit-backed fields would force a schema migration for zero user benefit.
- **Trophy currency text is computed at render time.** `TrophyCardView` builds the requirement hint and detail description for `.gold100`/`.gold500` from `requirementValue` via `CurrencyFormatter`, never from the stored `achievementDescription` (legacy records carry stale text).
- **Inputs stay plain-numeric.** Amount TextFields accept bare numbers; currency formatting is a display-boundary concern only.

### 8. Auth & Session State Machine

`AppState.AuthStatus` drives the root view:

```
restoringSession ──(has saved session)──► restoreSession(cloudKit)
                                                  │
                        ┌─────────────────────────┼─────────────────────────┐
                        ▼                          ▼                         ▼
              (network fail → cache fallback)   (CloudKit OK)         (no saved session)
                  authenticated              authenticated            checkingCloudData
                                                                        │
                                                               discoverExistingCloudState
                                                                        │
                                          ┌─────────────────────────────┼─────────────┐
                                          ▼                              ▼             ▼
                              detectedPreviousFamily(...)         onboarding    onboarding
                                  (private zone: Guild Master     (shared zone:
                                   discovered)                     Hero discovered)
                                          │
                            acceptDetectedFamily / rejectDetectedFamily
                                          ▼
                                   authenticated
```

- `discoverExistingCloudState` searches the **private** custom zones first (parent reinstall), then **shared** zones (hero), with a brief retry pulse for cold-launch share sync.
- `DetectedFamilyView` presents the "we found your old guild" branch; the user accepts (restores session) or rejects (deletes/abandons the zone or deactivates the profile).
- Session is persisted in `UserDefaults` (profile/family record names, zone ID, isOwner); `clearSession` wipes it.

### 9. Onboarding Flow (fresh start)

```
WelcomeView → "I'm a Parent" → sign in with iCloud → Create Family → Guild Master
                                                         └─ Invite Heroes via iCloud (CKShare)
           → "I'm a Hero"   → sign in with iCloud → accept share / enter family code
                                                         → Select Avatar Class → Ready to quest!
```

Incoming share URLs are captured in `LootListApp.handleIncomingShareURL` and passed to `OnboardingViewModel.pendingShareMetadata`.

### 10. Notification System

Every notification type is individually toggleable per user, stored as `NotificationPreference` records (one row per `profile + eventType`). `NotificationEventType` enumerates the app's events (quest lifecycle, level-up, money earned, spending logged, trophy earned, streak milestone) — the canonical list lives in `Project/Models/Enums/NotificationEventType.swift`, not here, since it changes as features ship.

**Cross-device source of truth:** `NotificationPreferenceCache` (SwiftData) is the per-device render cache backing `NotificationPreference` (CloudKit, system of record). `NotificationService.isNotificationEnabled(for:)` reads cache-first (filtered by `profileRecordName + familyRecordName + eventType`); `UserDefaults.standard.bool(for:)` is a **first-launch-only** fallback used solely when the SwiftData cache is cold (brand-new install before the first `syncAllForActiveZone` populates it) — this is the sanctioned strictly-subordinate-fallback category of the UserDefaults Policy (§2). `NotificationSettingsView` toggles write-through optimistically via `NotificationService.updatePreference(event:enabled:)` (optimistic upsert → CK save → re-upsert → catch-invalidate / snapshot-rollback) and keeps a `UserDefaults` mirror write for backward-compat. Bulk-write paths on `BackgroundCacheActor` — `batchUpsertNotificationPreferences` and `purgeMissingNotificationPreferences` — handle full-sync hydration and stale-row purge; `SyncEngine.processSecondaryRecord` routes incoming `NotificationPreference` records to `batchUpsertNotificationPreferences`. Cross-device propagation flows through the existing `CKSubscription` → `SyncEngine.incrementalSync` → SwiftData mutation → view's `.onChange(of: cachedNotificationPreferences)`.

### 11. Versioned Data Migrations

There are two migration tracks:

- **SwiftData schema migrations** — additive stored-attribute changes are applied by bumping the `VersionedSchema` and wiring a `.lightweight` stage in `LootListSchema`'s `SchemaMigrationPlan` (the sanctioned "schema bump" convention: SwiftData lightweight-migrates new attributes that carry defaults or optionals, so no custom stage is needed). The plan is currently `LootListSchemaV1` → `LootListSchemaV2` → `LootListSchemaV3` → `LootListSchemaV4` (1.0.0 → 2.0.0 → 3.0.0 → 4.0.0), with `CacheService` constructing the container on the V4 schema: V1→V2 adds `QuestCache.xpBanked` / `QuestCompletionCache.xpCredited`, V2→V3 adds `FamilyCache.payoutDay` (default `"sunday"`) / `ProfileCache.payoutDay` (optional), V3→V4 adds `FamilyCache.creatorUserRecordName` (optional).
- **Data backfills** — `DataMigrationsCoordinator` is a UserDefaults-versioned migration runner. Each migration is a `MigrationStep { id, version, run }`; `runPendingMigrations()` executes steps whose version is higher than the last-run version stored in UserDefaults. Example registered step: `questNameBackfillV1`. Migrations run at launch after the cache sync.

**Constraint:** any schema/data change that requires backfilling existing records must register a `MigrationStep` on `DataMigrationsCoordinator` — do **not** ad-hoc patch records inside services.

---

## Project Structure

The repo follows the MVVM/Services layout below. The exact file listing is intentionally omitted — it changes frequently and is trivially inspectable via `glob`/AST tools. What matters is the **shape**: each directory's role and the contracts it owes the rest of the app.

- **`Project/App/`** — `@main` (`LootListApp`), root `AppState` (auth/session state machine + session persistence), `AppDelegate`.
- **`Project/Models/CloudKit/`** — the source-of-truth record types (`Family`, `Profile`, `Quest`, `QuestTemplate`, `QuestCompletion` (CKRecordType `"QuestLog"`), `AllowancePeriod`, `LedgerEntry`, `Achievement`, `ProfileAchievement`, `NotificationPreference`) plus the `CloudKitRecord` encode/decode protocol and `CKDecodingError`. Every struct carries `changeTag: String?` mirroring CloudKit's `recordChangeTag` (see §Conflict). Where a field is a typed enum in code (`ApprovalMode`, `VerificationStatus`, `PayoutPolicy`, `PayoutStatus`, `QuestSchedule`, `QuestRarity`, `NotificationEventType`, `AvatarClass`, `AchievementCategory`, `AchievementRequirement`), it round-trips through that enum, not a raw `String`.
- **`Project/Models/Local/`** — the SwiftData `@Model` cache classes (one per CloudKit type), the `FamilyScopedCache` protocol they conform to (mandates `familyRecordName`), and `LootListSchema.swift` (the `VersionedSchema` + `SchemaMigrationPlan`, see §2).
- **`Project/Models/Enums/`** — the typed enums above, plus `CachedRecordType` (the typed delete-path enum, see §2).
- **`Project/ViewModels/`** — screen ViewModels (`@Observable`): hero & family dashboards, quest manager, treasury, trophy room, onboarding, and quest log. ViewModels read `*Cache` models directly and never depend on CloudKit types.
- **`Project/Services/`** — the protocol/concrete service layer: `CloudKitServiceProtocol` (the `@MainActor` seam consumed across the service layer and `AppState`), `CloudKitService` (owner/participant DB split, retry, share, zones, subscriptions), `FamilyService`, `QuestService`, `TreasuryService`, `SpendingService` (protocol; `ManualSpendingService` is the sole conformer today, `FinanceKitSpendingService` planned — §3), `AchievementService`, `NotificationService`, `AvatarService`, `XPService` (declaration site of the narrower `CloudKitServicing` protocol), `CacheService` (+ `CacheService+Fetches` / `CacheService+Invalidation` extensions), `BackgroundCacheActor`, `SyncEngine`, `AppSyncCoordinator`, `CacheConversions`, `ConcurrentEditDetector` (the `detectConcurrentEdit` guard and the actor-isolated `InFlightMutationRegistry` — see §2 and §Conflict), `ToastManager` (shared in-app/toast surface), and `DataMigrationsCoordinator`.
- **`Project/Views/`** — SwiftUI screens grouped by feature: `Onboarding/`, `Hero/`, `Treasury/`, `Trophies/`, `Profile/`, `Guild/`, `Shared/`. `Shared/` holds cross-cutting components (splash, settings, share sheet, presets, badges, progress bar, toast view, validation rows, etc.).
- **`Project/Utilities/`** — app-wide constants, ISO8601-UTC calendar helpers, `WeekMath` (half-open week ranges — see §5), reward proration, sample/seed data, and test-environment detection.
- **`Project/Resources/`** — asset catalogs (AppIcon + avatar imagesets, AchievementIcons).
- **`ProjectTests/`** — unit tests; **`ProjectUITests/`** — UI + snapshot tests (`SnapshotHelper`).

---

## Achievement List (V1)

The 12 launch trophies and their unlock criteria. This is a **product spec**, not code detail — the enum that implements it (`AchievementService.AchievementRequirement`) must keep-to this list. Currency thresholds are stored as plain numbers (100 / 500) and rendered through `CurrencyFormatter` (§7.1) at display time, so a UK user sees "Earn £100.00 lifetime" and a US user sees "Earn $100.00 lifetime".

| Name | Description | Requirement |
|---|---|---|
| First Steps | Complete your first quest | 1 quest completion |
| Questing Squire | Complete 10 quests | 10 quest completions |
| Quest Knight | Complete 50 quests | 50 quest completions |
| Quest Legend | Complete 100 quests | 100 quest completions |
| Week Warrior | Complete all quests in a week | 100% weekly completion |
| Iron Will | 7-day streak | 7 consecutive days |
| Unstoppable | 30-day streak | 30 consecutive days |
| Fortune Hoarder | Earn 100 lifetime (local currency) | 100 total earned (local currency) |
| Fortune Magnate | Earn 500 lifetime (local currency) | 500 total earned (local currency) |
| Chronicler | Log 10 spending entries | 10 ledger entries |
| Wise Spender | Log spending for 4 weeks | 4 weeks of entries |
| Early Bird | Complete a quest before 9 AM | 1 quest before 9 AM |

---

## Sync & Conflict Resolution

### General Policy

- **CloudKit = source of truth.** Last-write-wins for most fields is handled automatically by CloudKit.
- **QuestCompletions are append-only** — no conflicts possible. Each `QuestCompletion` row is created with a fresh `UUID().uuidString` record ID, and the quest service exposes an insert path only — there is no update path, so completion records are append-only by convention as well as structurally.
- **Profile XP/Level is derived** from QuestCompletions, not directly edited. `level` is computed from `xp` via `XPService.level(forXP:)`, and `xp` is updated through `XPService.addXP` on the QuestCompletion save path; views read these derived values rather than storing them independently.
- **Family settings are Guild-Master-only** (role-gated in `FamilyService`, where the settings-update methods short-circuit for non-owner roles).
- **Local SwiftData cache is derived, not authoritative.** It is hydrated by `SyncEngine.syncAllForActiveZone()` and kept current by the service write-through pattern (§2). `CacheService.clearAll()` may be used to force a full re-hydrate (it also clears the freshness watermarks so no stale stamp outlives the wipe).
- **Offline launch fallback:** if `restoreSession` cannot reach CloudKit, it reconstructs `Family`/`Profile` from the cache and authenticates in offline mode; the next successful sync reconciles.

### Background Fetch & Push Outcome Policy

- **Every sync pass reports a terminal outcome.** Both the full-sync paths (`syncAllForActiveZone()` / `syncAll(familyRecordName:)`) and `incrementalSync` post `.syncDidComplete` with a `SyncOutcome` in the notification's `userInfo` (under `SyncOutcome.userInfoKey`, the `"syncOutcome"` key): `.changed` when any record arrived or was deleted, `.noChange` when the pass completed with no deltas, `.failed` when the pass errored (a full-sync pass also attaches the per-type error strings under `"errors"`).
- **Background fetch maps the outcome to iOS's expectation.** `AppDelegate.didReceiveRemoteNotification` runs the sync, awaits the terminal `.syncDidComplete` outcome (or a 25-second timeout), and resolves the fetch completion handler exactly once: `.changed → .newData`, `.noChange → .noData`, `.failed → .failed`. A timeout with no terminal outcome resolves as `.failed`, so iOS retries the push rather than throttling it.
- **Cross-context propagation safety net.** `CacheService` observes `ModelContext.didSave` and, when the saved context is a background context of the same container, forces `mainContext.processPendingChanges()` so `@Query` results re-fire deterministically even when the OS misses automatic cross-context propagation; the observer task is cancelled in `deinit`. This keeps UI state converged with background-context sync writes without any view-side polling.

### Conflict Resolution Strategy

- **Field-level policy:** **last-write-wins** for the majority of fields. CloudKit resolves concurrent edits to the same record by accepting the most recent change and propagating it to all participants.
- **Per-record version tracking is provided by CloudKit**, not by the app. CloudKit maintains an internal per-record version (surfaced via the `serverRecordChanged` error path on `CKModifyRecordsOperation`) that the runtime consults when a save would clobber a newer server copy. The app does **not** consult a per-record version on every read — only CloudKit does, and only on the save path.
- **`*Cache` rows carry a `changeTag: String?` mirroring CloudKit's `recordChangeTag`.** This field is used by the `detectConcurrentEdit` guard in the service layer to detect concurrent edits before rolling back an optimistic write. The cache itself does not *resolve* write conflicts — CloudKit remains the sole conflict-resolution authority through its `serverRecordChanged` mechanism.
- **Append-only record types sidestep field conflicts.** `QuestCompletion` rows are never updated, so concurrent edits are not a concern for that type (see General Policy above).

### Optimistic Write & Rollback

Every mutating service writes through to the cache **optimistically** — it upserts the new state into the SwiftData cache *before* awaiting the CloudKit save, so the UI reflects the change instantly (0ms) and remains usable offline. On CloudKit save failure the service rolls the cache back so the UI does not hold a state that the source of truth rejected. This snapshot/rollback pattern is practiced uniformly across the mutation services (`XPService`, `FamilyService`, `QuestService`, `TreasuryService`, `ManualSpendingService`, `AchievementService`, `NotificationService`) and is covered by tests in `ProjectTests/Services/`.

- **Snapshot is captured BEFORE the optimistic write.** The service fetches the current cached row, converts it back to its CloudKit domain type, and holds that value as the pre-mutation snapshot. It then performs the optimistic upsert and awaits `cloudKit.save`.
- **On save failure, the snapshot is restored.** The pre-mutation snapshot is upserted back over the optimistically-written row, so the cache returns to its prior value and the UI reverts.
- **Brand-new records have no prior snapshot.** When the mutation creates a record that did not exist in the cache, there is nothing to restore; the service instead **invalidates** (removes) the optimistically-inserted cache row so the UI does not display a phantom record that CloudKit never accepted.
- **What this protects against.** The snapshot-restore keeps the cache consistent with CloudKit in the common failure modes: network/refusal errors, exhausted retry budget (`CloudKitService.retrying()` → `retryable` / `exhaustedBudget`), and per-save `serverRecordChanged` rejections. In all these cases the snapshot-restore gives the user a coherent, CloudKit-backed value rather than a stranded optimistic value.
- **The optimistic window is registered against background sync.** Every mutation registers its `recordName` in the shared `InFlightMutationRegistry` (an actor owned by `CacheService` and injected into `BackgroundCacheActor`) before the optimistic upsert, and deregisters once the CloudKit save settles — success or terminal failure, with the rollback running while the name is still registered. `BackgroundCacheActor.batchUpsert*` skips registered rows (§2), so a background incremental sync never overwrites an in-flight optimistic write with stale server data; the author's post-save re-upsert reconciles the row.

### Concurrency Limitation & Future Hardening

The optimistic write-through pattern keeps a tiny window open: between the local `cacheService?.upsertX(updated)` (optimistic) and the `await cloudKit.save(...)` returning, another device may have written to the same record. If our save fails outright on a non-conflict reason (network, transient), we restore the pre-mutation snapshot. If our save fails because the server has a newer record (the canonical optimistic-concurrency signal), the `detectConcurrentEdit` guard discards our optimistic value and re-fetches the authoritative server record instead.

#### Version-Tag Guard (implemented)

All `*Cache` SwiftData `@Model` classes carry a `changeTag: String?` mirror of CloudKit's `recordChangeTag`. The CloudKit typed structs likewise carry `changeTag` populated in `init(record:)` from `record.recordChangeTag`. This changeTag is propagated through `BackgroundCacheActor.batchUpsert*` and the per-record `CacheService.upsertX` paths.

A single centralized guard — `enum ConcurrentEditDetector` in `Project/Services/ConcurrentEditDetector.swift` — exposes `detectConcurrentEdit(preMutationChangeTag:fetchCurrent:error:) -> Bool`. The mutation services (`QuestService`, `TreasuryService`, `FamilyService`, `XPService`, `AchievementService`, `ManualSpendingService`) invoke this guard on the snapshot-rollback path. The helper consults two independent signals — either is sufficient:

- **Signal 1 — CloudKit `serverRecordChanged`.** The `CloudKitService` wraps raw `CKError.serverRecordChanged` into `CloudKitServiceError.serverRecordChanged`. When `cloudKit.save(X)` raises this, the server has a newer record and `detectConcurrentEdit` returns true.
- **Signal 2 — changeTag divergence.** The caller captures `snapshot?.changeTag` from the cache row BEFORE the optimistic `upsertX(updated)` and passes a closure that re-fetches the row's `changeTag` AFTER the throw. If both values are non-nil and unequal, `detectConcurrentEdit` returns true.

On a concurrent edit, the service:

1. emits a `.warning` toast *"Data was modified by another device. Refresh to see the latest."* via the shared `ToastManager` (the `@MainActor` toast infrastructure held as `var toastManager: ToastManager?` by the mutation services);
2. re-fetches the authoritative server record via `cloudKit.fetch(X.self, id: ...)` and writes it to the cache via `cacheService?.upsertX(fresh)` — replacing the rejected optimistic value with the truth;
3. falls back to the pre-mutation snapshot restore via `upsertX(snapshot.toX(...))` if the re-fetch also fails (the snapshot is stale; `SyncEngine.syncAllForActiveZone()` will reconcile on the next successful sync);
4. for `QuestService`/`TreasuryService`/`FamilyService`: still throws the original error so the caller's ViewModel observes a save failure. For `XPService.addXP`: returns the freshly-fetched Profile (or, on fallback, the pre-mutation `snapshotProfile`).

#### Remaining Limitations

These remain tracked as hardening items:

- The pre-`save` window (between the optimistic `upsertX(updated)` and `await cloudKit.save(...)` completing) is short enough that the only reliable concurrent-edit signal during it is Signal 1 — CloudKit's synchronous `serverRecordChanged`. Signal 2 catches divergence that arrived via a background `SyncEngine.incrementalSync` push during the `await`. `changeTag` is copied **unconditionally** on every upsert path — the `CacheService.upsertX` single and batch variants and `BackgroundCacheActor.update(from:)` alike assign `target.changeTag = incoming.changeTag` without guarding on nil, because a `nil` incoming tag is a meaningful "no further tag" value that must propagate (it clears the cached tag rather than leaving a stale tag in place). Signal 2 therefore fires only when the pre-mutation tag and the re-fetched cache tag are **both non-nil and unequal**; when the incoming struct carries `nil`, the cache tag is cleared and Signal 2 is nullified for that path.
- In the rare case where the concurrent-edit re-fetch also fails (network unavailable, server returns no fresher record), the fallback restores the pre-mutation snapshot. The snapshot is a stale value, not truth; the next successful `SyncEngine.syncAllForActiveZone()` reconciles.
- `AchievementService` and `ManualSpendingService` now use the same optimistic-rollback pattern AND wrap their rollback with `detectConcurrentEdit`, aligned with QuestService, TreasuryService, FamilyService, and XPService.

---

## CloudKit Share Permission (load-bearing — do not change)

`CKShare.publicPermission` is set to `.readWrite` in `CloudKitService.createShare` and `fetchOrCreateShareURL`. This is **REQUIRED**, not a misconfiguration:

- The public share link is the **only** family-join mechanism. Users are never added as explicit participants.
- A user who accepts a share via the public link becomes a participant whose permission mirrors the share's `publicPermission`. With `.readOnly` they would be read-only and every hero write (profile save, quest completion, spending, payout) would fail — the app would be unusable for non-owners.
- The share URL is a **bearer credential** for family membership (read **and** write). Treat it as sensitive. If it leaks, create a new share to rotate it.
- Role-based rules are enforced client-side only; CloudKit provides no server-side business-rule validation. See §Authorization Model below.

---

## Authorization Model

Privileged mutations — role changes, member removal, payout finalization, quest verification — are enforced at the service layer by verifying the acting profile's role (parent role) before mutating; unauthorized callers get `FamilyServiceError.unauthorized`. This is defense-in-depth against in-app callers (deep links, shortcuts, accidental callers).

It does **not** by itself stop a malicious CloudKit participant from forging raw `CKRecord` writes directly into the shared zone. The owner anchor hardens the highest-privilege, irreversible operations (see below); reward minting and other remaining client-side operations are documented accepted residual risk.

## Authorization owner anchor

Role field alone is forgeable — a malicious participant who accepts the public `readWrite` share link can issue a raw `CKRecord` write creating a `Profile` with `role = .guildMaster` bound to their own iCloud user ID, and every parent-role guard would then pass. To close this, the highest-privilege, irreversible family operations are anchored on the **server-authenticated CloudKit identity** rather than the forgeable `Profile.role` field:

- **`Family.creatorUserRecordName`** mirrors CloudKit's server-stamped, read-only `CKRecord.creatorUserRecordID` — the iCloud user record name of the user who created the family record. It is decoded **only** on the read path in `init(record:)` (from `record.creatorUserRecordID?.recordName`) and is **never authored locally**: `toRecord()` does not write the field, exactly mirroring the `changeTag` precedent for server-owned fields. Because CloudKit itself controls the creator stamp (saves cannot spoof it), a participant cannot rewrite the anchor — unlike a locally-authored field. The value is mirrored into `FamilyCache` for cache-first reads.
- **Irreversible owner-gated operations** — `deleteFamilyAndReset`, `updateMemberRole`, `kickMember` — require the server-authenticated user to equal the family's creator (`isFamilyOwner`), evaluated against `currentUserRecordID()` at enforcement time. Deny-by-default when the creator is unresolved: a nil `creatorUserRecordName` (record not yet stamped, or legacy row) never grants ownership on its own.
- **Reversible owner-OR-parent operations** — `updateFamilyName`, `updatePayoutPolicy`, `updatePayoutDay` — remain available to any parent (Guild Master / Ranger) *or* the owner anchor, so a Ranger can still manage family settings while only the founding owner can perform irreversible membership/role/deletion actions.
- **Legacy fallback:** families predating the anchor (nil `creatorUserRecordName` — the creator is unresolved) fall back to the legacy check — parent-role for `updateMemberRole`/`kickMember`, and zone-owner + parent-role for `deleteFamilyAndReset`. This keeps existing families fully functional without a backfill.
- **Profile self-service operations** (`updateProfilePayoutPolicy`, `updateProfilePayoutDay`, `updateProfileDisplayName`, `updateProfileAvatar`) are unchanged — they gate on self/Parent and are not owner-anchored.

**Accepted residual risk:** reward minting (quest verify/reject, `runPayout`, `applyReward`) runs client-side and remains forgeable by a participant; fully closing it requires a server-side validation layer. **V2 note:** replace the public bearer-URL share link with explicit per-participant invites and integrate FinanceKit (both already planned for V2) to shrink the remaining attack surface.

---

## Security Audit: Accepted Risk Register (non-findings)

This register codifies deliberate, load-bearing security decisions that are **accepted risk**, not defects. The security-audit gate must classify findings that merely restate the blast radius of an entry in this register — without introducing a new, concrete, in-scope exploit or a concrete alternative design — as **non-findings** and must NOT fail the build on them.

### AR-001 — `CKShare.publicPermission = .readWrite` bearer share link

**Location:** `Project/Services/CloudKitService+Sharing.swift` (`createShare` sets `share.publicPermission = .readWrite`; `fetchOrCreateShareURL` also enforces `existingShare.publicPermission = .readWrite` on the retrieve path).

**Status:** ACCEPTED (load-bearing; do not alter).

**Rationale:**

a. The public share link is the **sole** family-join mechanism; participants join via `FamilyService.joinFamilyViaShare` → `CloudKitService.acceptShare`, never as explicit per-user `recordID` participants.

b. CloudKit applies one `publicPermission` to **all** participants who accept via the public link. Setting `.readOnly` would strip write access for every Hero — profile saves, quest completions, spending logging, and payout would all fail, making the app unusable for every non-owner participant. The app currently has NO server-side business-rule layer where authenticated write-gating could be enforced.

c. Highest-privilege irreversible operations are already defended against the read/write bearer link by the server-stamped `Family.creatorUserRecordName` owner anchor (see Authorization owner anchor): `deleteFamilyAndReset`, `updateMemberRole`, `kickMember` require the caller's server-authenticated identity to equal the family creator, so accepting the public readWrite link does not grant zone-deletion or role/kick powers.

**Mitigations already in place:** client-side role gating in the service layer; the creator anchor above; share rotation (mint a new share to rotate a leaked URL).

**Closure note:** the public bearer link is an accepted residual risk until V2 replaces it.

**Security-audit directive:** A finding that merely restates the readWrite/read-only blast radius of this share WITHOUT introducing a new, concrete, in-scope exploit OR a concrete per-participant-write design must be classified as a NON-FINDING (matches this register) and must NOT fail the gate.

### AR-002 — Local auth is client-side only; CloudKit provides no server-side business-rule validation

**Status:** ACCEPTED (documented, defense-in-depth only).

The absence of a CloudKit-side business-rule layer means authenticated write-gating happens in the service layer (client-side role checks) plus the `creatorUserRecordName` owner anchor for the highest-privilege operations, as documented in the Authorization owner anchor section.

**Security-audit directive:** This is an accepted reverse residual risk; do not fail the gate on the absence of a server unless a concrete in-scope vulnerability is shown.

---

## Key Patterns

### MVVM + Protocol Services
- Views observe ViewModels via `@Observable` (iOS 17+, preferred over `ObservableObject`/`@Published`).
- ViewModels depend on service protocols/concrete services, not on CloudKit directly. The cross-service CloudKit seam is `CloudKitServiceProtocol` — services and `AppState` hold `any CloudKitServiceProtocol`, with `CloudKitService` and `MockCloudKitService` as conformers. Where a service benefits from a narrower mock seam, a small `@MainActor` protocol is declared alongside the service — `CloudKitServicing` (next to `XPService`) abstracts `CloudKitService.save/fetch`, and `SpendingService` (§3) abstracts the ledger provider so the manual → FinanceKit swap is a drop-in conformer change.
- Services are injected via `@Environment` or initializer injection at `LootListApp`. The cache is injected as an **optional** `CacheService?` so services degrade gracefully when the cache is unavailable.

### CloudKit Integration
- **Container:** `CKContainer(identifier: "iCloud.com.volcrypt.lootlist")` (via `CloudKitService.defaultContainer`).
- **Database selection:** always go through `CloudKitService.database(isOwner:)` — never assume `sharedCloudDatabase`.
- **Subscriptions:** `CKSubscription` per zone, managed by `AppSyncCoordinator` + `CloudKitService.SubscriptionManager` (an actor that holds per-recordType change-stream continuations). `CloudKitService.changes(for:)` exposes an `AsyncStream`; `broadcastChange` fans events to subscribers.
- **Retry/backoff:** `CloudKitService.retrying()` with `backoffSchedule = [0.5s, 1.5s, 4s]`, `maxRetries = 3`. Failures surface as `CloudKitServiceError` (the full case set lives in `Project/Services/CloudKitService.swift`; notably `serverRecordChanged` is the canonical concurrent-edit signal used by §Conflict).
- **Shares:** `createShare` / `fetchOrCreateShareURL` / `acceptShare`; incoming share URLs handled via `.onOpenURL` → `pendingShareMetadata`.
- **Tests:** CloudKit mocks are returned when `TestEnvironment.isRunningUnitOrUITests`; use `SampleData.populate` to seed both CloudKit mocks and the in-memory cache.

### Local Cache Integration
- Services hold `var cacheService: CacheService?` and **write through** to the cache on every successful CloudKit write.
- Reads may use `*FromCache(_:zoneID:)` helpers to reconstruct CloudKit model types from cached rows when offline.
- Do **not** add a new cached model type without: (a) a `*Cache` `@Model` class with `@Attribute(.unique) recordName` + `familyRecordName` (conforming to `FamilyScopedCache`), (b) a `convenience init(from:)`, (c) `CacheConversions` functions, (d) an upsert path on `CacheService` (with fetch/invalidation helpers as needed in `CacheService+Fetches` / `CacheService+Invalidation`), (e) write-through in the owning service.

### Data Migrations
- Schema/data backfills register a `MigrationStep` on `DataMigrationsCoordinator` (versioned via UserDefaults). Do not patch records ad-hoc inside services. (Note: SwiftData schema migrations are wired through `LootListSchema`'s `SchemaMigrationPlan` — `LootListSchemaV1` → `LootListSchemaV2` → `LootListSchemaV3` → `LootListSchemaV4`, each a `.lightweight` stage, with V3→V4 adding `FamilyCache.creatorUserRecordName`; see §11.)

### Code Commenting Guidelines
Code should be self-documenting through clear naming, clean structure, and descriptive method signatures. Avoid obvious, redundant, or multi-paragraph comments on self-explanatory code.

**Rules for comments:**
1. **New File Headers:** Every new file must include a standard Xcode header:
   ```swift
   //
   //  <FILE_NAME>.swift
   //  LootList
   //
   //  Created by Ben Mackin on <SYSDATE>
   //
   ```
2. **Edge Cases & Non-Obvious Functions:** Add comments when documenting edge cases, complex non-obvious functions, or OS/concurrency workarounds.
3. **Unique Context:** Add a comment only if there is something truly unique that a future developer must know about that specific line or block of code.
4. **No Planning Artifact References:** Never reference blueprint plan session IDs, task IDs, PRs, or planning items (e.g. `D1`, `D3`, `Task 123`, blueprint IDs) in comments. Describe code behavior or domain rules directly without referring to historical planning metadata.

### SwiftUI Best Practices (iOS 26)
- Use `@Observable` macro (not `ObservableObject` / `@Published`).
- Use `NavigationStack` (not `NavigationView`).
- Use `@State`, `@Binding`, `@Environment` for state management.
- Use SF Symbols 6+ for icons.
- Use `.containerRelativeFrame()` for adaptive layouts.
- Use `.scrollTargetBehavior()` for scroll snapping.
- Avoid deprecated APIs: `UIApplication.shared.openURL`, `UIDevice.current`, etc.

---

## Testing

Unit tests live in `ProjectTests/` (mirroring the source layout: `Models/`, `Services/`, `Utilities/`, `ViewModels/`); UI and snapshot tests live in `ProjectUITests/` (per-screen XCTestCases plus `LootListScreenshotTests` via `SnapshotHelper`). The exact test list is intentionally omitted — it is inspectable via tree/glob and grows with the codebase.

**Test-environment contract (this is the architectural part, not the file list):**
- `TestEnvironment.isRunningUnitOrUITests` is the single switch. When true: `CacheService` is constructed with `inMemory: true`; CloudKit availability is short-circuited so mocks are returned instead of live databases; and `SampleData.populate(cloudKit:cacheService:)` seeds both the CloudKit mocks and the in-memory cache with a consistent fixture set.
- **CLI args** (`--onboarding`, `--parent`) select the seeded auth status, so UI tests can drive a screen deterministically without replaying the full onboarding flow.