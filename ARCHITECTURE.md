# ARCHITECTURE.md — Loot List

## 1. System Overview & Intent

A family chore-and-allowance tracker for iOS with **utility-first gamification**: parents ("Guild Masters") assign Quests; kids ("Heroes") complete them and allocate earnings toward Spend / Short Term Save / Long Term Save buckets and self-set savings Goals. Delight comes from progress rings, haptics, celebratory particles, streak badges, and unlockable alternate app icons — NOT from an in-game avatar. Data lives in a CloudKit custom zone shared via `CKShare`; a local SwiftData cache is the immediate UI source of truth and CloudKit is the cloud system of record.

**Gamification contract:** the only sanctioned gamification surfaces are visual momentum (progress rings for weekly chore goals and budget targets), feedback loops (haptics, particle celebrations on completion, unlockable badges/app icons from savings streaks), and targeted framing (money is *allocated* to Goals, never "subtracted"). The legacy fantasy-RPG layer — sprite avatars, Hero classes, leveling display, quest rarity, journey path, mascots, gems, gear, loot drops, daily login rewards — is **hidden behind `FeatureFlags.rpgImmersive` (default false), never deleted**, so it can be re-enabled later. XP still accrues invisibly through the existing reward pipeline (flat 50xp/quest default). The Trophy Room remains visible; its criteria are quest-completion counts plus goal-based achievements.

Domain rules agents must not misinterpret:
- Roles: Guild Master (owner, private DB) / Ranger (co-parent) / Hero (participant, shared DB). Role drives which database every operation targets.
- Quest approval: `ApprovalMode` (`.autoApprove` default / `.parentVerify`) set per `QuestTemplate` or per quest. Completions transition `.pending → verified/rejected/withdrawn`; parent notifications fire on `.pending`.
- `Quest.rarity` remains derived from XP (`QuestRarity.from(xp:)`), never stored — but is NEVER rendered while the RPG layer is flagged off.
- Week cycles are payout-day-aware half-open `[start, end)` ranges owned exclusively by `WeekMath`. Never compute week boundaries elsewhere. Effective payout day resolves profile override → family → `.sunday`.
- XP-credit idempotency is structural: `QuestCompletion.xpCredited` marks a completion as already credited; credits are immutable `RewardEvent`s with DETERMINISTIC IDs (`reward-{completionID}`) so CloudKit dedupes across devices. Never switch these to random UUIDs. ALL money-movement records (contributions, interest, matches, transfers, imports) follow the same deterministic-ID discipline:
  - Goal contributions: `contrib-{goalRecordName}-{sourceEventID}`
  - Interest credits: `interest-{profileRecordName}-{yyyy-MM}` (monthly, check-before-apply)
  - Parent match: `match-{goalRecordName}-{sourceContributionEventID}`
  - Bucket transfers: `transfer-{profileRecordName}-{transferID}` (or timestamp+nonce when unkeyed)
  - CSV imports: `import-{rowContentHash}` (re-import idempotent)
- Buckets are exactly three (`BucketKind`): spend, shortTermSave, longTermSave. A child's split percentages apply to FUTURE payouts/deposits only — never retroactively rebalance.
- Goals fill FIFO within their bucket: oldest incomplete non-archived goal fills first; overflow cascades; surplus past all goals sits unallocated in the bucket.
- LedgerEntry `source` allowed values include: `manual`, `interest`, `match`, `transfer`, plus import-tagged entries. Money copy always renders as real region currency via `CurrencyFormatter` — never hardcoded symbols, never "gold" copy.
- Trophy requirement text is computed at render time from values; stored description text may be stale on legacy records. `AchievementService.AchievementRequirement` must stay in sync with the trophy spec (quest-count tiers + "First Goal Created" + "Goal Getter").
- Internal identifiers keep legacy `gold` prefixes (`goldReward`, `Color.gold`, …). Do not rename them. `Color.gold` is asset-catalog-backed via `Assets.xcassets/gold.colorset` (light `#D9A834` / dark `#E8C05C`) matching `DesignSystemConstants.Colors.gold = "gold"` and resolved via asset symbol synthesis / `Color("gold")`; manual `ColorExtensions` wrappers must not be reintroduced.
- User-facing copy keeps Quest/Hero/Guild vocabulary but contains NO level/XP/rarity/gold/journey/gem/gear/mascot references while the RPG layer is hidden. `FlavorTextProvider` carries this voice.

## 2. Core Tech Stack & Constraints

- Swift 6.0 strict concurrency, SwiftUI, iOS 26+ minimum. XcodeGen builds the project. Container: `iCloud.com.volcrypt.lootlist`.
- Persistence: SwiftData cache schema `LootListSchemaV10` (`VersionedSchema`, wraps `LootListSchemaV9` model set, current typealias `LootListSchema`) + CloudKit via native `CKSyncEngine`. Schema V10 (Version 10.0.0) is a lightweight index-only migration for `LedgerEntryCache` retaining the pre-existing base composite index `[\.familyRecordName, \.recordName]` (family-scoping) and adding `[\.familyRecordName, \.profileRecordName, \.date]` and `[\.familyRecordName, \.profileRecordName, \.source, \.date]` — three total indexes on `LedgerEntryCache`, no new models/properties; `fromBucket`/`toBucket` are sparse optionals excluded from the DB predicate and filtered in-memory on the small indexed subset to avoid table scans; indexes are eligible for lightweight migration with fallback destructive reset in `CacheService` if lightweight migration is unavailable. Schema V8 adds: `GoalCache` record type; SavingsConfig fields on Profile (split percentages, interest rate/bucket/simple-vs-compound, match rate/cap); LedgerEntry bucket attribution fields (`bucketKind?`, `fromBucket?`, `toBucket?`); Quest claim fields (`claimedByProfileRecordName?`, `claimedAt?`); Profile `avatarEmoji`. 12 of the 13 reconciled cache types are family-scoped (`FamilyScopedCache`, composite index `familyRecordName` + `recordName`) and reconciled each lifecycle pass via the §4 snapshot (`AppLifecycleCoordinator.fetchSnapshot` → `BackgroundCacheActor.reconcileParticipantSet` / `handleIncomingRecordsDirectly`): `ProfileCache`, `QuestCache`, `QuestTemplateCache`, `QuestCompletionCache`, `LedgerEntryCache`, `AllowancePeriodCache`, `GoalCache`, `AchievementCache`, `ProfileAchievementCache`, `NotificationPreferenceCache`, `GemLedgerCache`, `RewardEventCache`. `FamilyCache` is the intentional 13th root exception — `@Model final class FamilyCache: CacheMergeable` (NOT `FamilyScopedCache`) with `#Index<FamilyCache>([\.recordName])` only; WHY root: the family IS the partition, so `familyRecordName` would be circular/self-referential (`recordName` IS the partition key). WHY no migration: adding a persisted `familyRecordName` + composite index would require a schema migration/backfill (or destructive reset) for zero isolation gain — `FamilyCache` rows are already isolated by `recordName` and fetched via `fetchDescriptor(recordName:)`; docs intentionally keep single-column index to avoid breaking migration. `AchievementCache` / `RewardEventCache` / `ProfileAchievementCache` have been present since V7 — schema version unchanged for those types; V8 adds only `GoalCache` (V9 wraps V8 with same 13 models, adding `GoalCache.targetDate`/`linkURL`/`imageURL` without new reconciled types (no longer current; superseded by V10); container initializes via `LootListSchemaV9.models`). Incompatible-change destructive cache reset + rehydration applies as always.
- Strict constraints:
  - Views/ViewModels NEVER call CloudKit directly or hold raw `CKRecord`s/domain structs for presentation. All reads are `@Query` on `*Cache` models.
  - All mutations go through Services → `CacheService` write + `CKSyncEngineCoordinator.enqueueSave/enqueueDelete`.
  - Engine-delivered and query-derived server→cache record writes ride ONE entry point: `CKSyncEngineDelegateHandler.ingest(records:databaseScope:zoneID:notifiesOnCompletion:)`. Exactly two sanctioned exceptions: non-owner cache reconciliation via `BackgroundCacheActor.reconcileParticipantSet` (§4) and pre-session bootstrap mirrors in FamilyService during family creation/join, where ingest fails closed before a session exists (the owner-side §4 snapshot pass is NOT an exception — it rides ingest() via `handleIncomingRecordsDirectly`). Never query-then-upsert directly into cache outside those two doors.
  - Every `*Cache` row except `FamilyCache` is family-scoped (`FamilyScopedCache`, composite index `familyRecordName` + `recordName`); `FamilyCache` is the intentional root exception (`CacheMergeable` only, `#Index([\.recordName])`, computed `familyRecordName == ""`) — WHY root: family is the partition, so scoping it to itself is circular. Cross-family isolation for scoped types enforced at fetch/store layer, not downstream filtering.
  - Conflict merge semantics are FROZEN: quest banked XP max-merge capped at xpReward; Profile XP additive vs lastSyncedXP baseline with max-floor fallback; xpCredited non-nil preserve; AllowancePeriod uses monotonic-advance merge (highest-rank status wins) rather than strict server authority, and paidDate uses server-preferred-with-client-fallback, with client-wins display overlays. Changes require architecture review. Hero Board claim races resolve via standard server-wins conflict resolution (loser's ingest reveals the other claimer).
  - Services and AppState depend on `any CloudKitServiceProtocol` (narrower seams exist where useful). Do not concrete-type CloudKit dependencies.
   - UserDefaults is device-local only: session keys, migration flags, freshness watermarks, `FeatureFlags.rpgImmersive`, badge/icon eligibility. NEVER authoritative cross-device domain data (balances, counters, credits).
      - Cache reads are freshness-only authoritative: `CacheService.isCacheAuthoritative(familyRecordName:type:scope:)` returns true iff a hydration watermark exists for the family/type/scope (`isCacheFresh`); no wall-clock TTL. Stale cache — even non-empty — is never authoritative until re-hydrated or explicitly invalidated. Offline fallback renders hydrated cache instantly; background `CKSyncEngine` reconciles deltas.
    - Every screen supports light AND dark mode via semantic design tokens (`DesignSystemConstants` / asset-catalog colors such as `gold.colorset`). No hardcoded colors in views.
    - Concurrency Invariants:
      - Under Swift 6 (SE-0412), `let` constants of `Sendable` types (`Mutex<T>`) on `@MainActor` classes (such as `CacheService.backgroundWriterLock` and `bootstrapLock`) are non-isolated, data-race safe, and accessible from any context (including `deinit`) without `nonisolated(unsafe)`.
      - Static accessors forwarding to `@MainActor` state (such as `NotificationRouter.shared` forwarding to `AppDependencies.shared`) are explicitly annotated `@MainActor`, guaranteeing compile-time race safety for UI callers without runtime `Thread.isMainThread` / `MainActor.assumeIsolated` dynamic checks. Off-main callers must await.

## 3. Directory Structure & Component Roles

```
Project/
├── App/            # @main, AppState (auth state machine + session persistence),
│                   # AppDelegate (APNs), AppLifecycleCoordinator (ALL sync/payout/
│                   # migration triggers centralized here; single-flight state)
├── Models/
│   ├── CloudKit/   # Domain structs mirroring CKRecords (wire types)
│   ├── Local/      # SwiftData *Cache @Models, FamilyScopedCache protocol,
│   │               # LootListSchemaV10 (VersionedSchema, wraps V9)
│   └── Enums/      # Typed enums incl. CachedRecordType, BucketKind
├── Services/       # Business logic layer:
│   ├── CloudKitService(+extensions)  # DB selection, zones, shares, retry
│   ├── Quest/Treasury/Family/Bucket/Goal/Interest/Match/HeroBoard/
│   │   XP/Spending/Achievement/LedgerExport/LedgerImport/Notification services
│   ├── CacheService(+Fetches/+Invalidation)  # @MainActor SwiftData CRUD for 0ms UI
│   ├── BackgroundCacheActor  # @ModelActor, autosaveEnabled=false, ALL off-main
│   │                         # server→cache writes; SerialMutationQueue-linearized;
│   │                         # exactly one save per batch pass
│   ├── CKSyncEngineCoordinator     # @MainActor engine lifecycle, enqueue buffers,
│   │                               # state serialization, watermark stamping
│   ├── CKSyncEngineDelegateHandler # delegate events + ingest() entry point for
│   │                               # engine-delivered/query-derived records;
│   │                               # sanctioned exceptions: §4 reconciliation
│   │                               # door + FamilyService pre-session mirrors
│   ├── CKSyncConflictResolver      # serverRecordChanged/deleted merges (frozen rules)
│   ├── RecordBridge                # SwiftData → CKRecord synthesis on demand
│   └── DataMigrationsCoordinator   # versioned MigrationStep runner
├── ViewModels/     # @Observable screen state; operate directly on *Cache models
├── Views/          # SwiftUI screens grouped by feature; Shared/ + Components/ =
│                   # cross-cutting components (ProgressRingView, StatCard,
│                   # BucketTileView, GoalCardView, ChoreRowCard, CelebrationOverlay)
└── Utilities/      # Constants/design tokens, WeekMath, CurrencyFormatter,
                    # FlavorTextProvider, FeatureFlags, HapticsService, TestEnvironment
ProjectTests/       # Unit tests (MockCloudKitService/MockRecordStore injected doubles)
ProjectIntegrationTests/  # Live CloudKit, Development env only, self-cleaning test zones
```

Where new files go: sync-engine code in `Services/`, lifecycle in `App/`, new cached entity models in `Models/Local/` (+ enum in `Models/Enums/`), screen code under its feature folder in `Views/`, reusable UI in `Views/Components/`. `LedgerImportView` canonical location is `Project/Views/Treasury/LedgerImportView.swift` (staging sheet presented from `PayoutHistoryView`); `Project/Views/Guild/LedgerImportView.swift` is intentionally absent — Treasury is the single source of truth (duplicate removed; no Guild shim needed).

Adding a new cached record type (except the singular `FamilyCache` root exception) REQUIRES all of: `*Cache` @Model conforming `FamilyScopedCache` with composite index `familyRecordName` + `recordName`; a `CachedRecordType` case; decode/init path in `CacheConversions`; upsert/fetch/invalidate helpers on CacheService; write-through in owning service; ingestion coverage via the pipeline. `FamilyCache` remains `CacheMergeable` only with `#Index([\.recordName])` — WHY no composite index: adding persisted `familyRecordName` would force a schema migration/destructive reset for a self-referential key with no isolation benefit.

## 4. Data Flow & Lifecycle

**Reads:** `@Query(*Cache)` → view/ViewModel. Family-scoped views filter at init via predicate-bound queries. Offline-safe by construction.

**Writes (local-first):**
`View action → Service → CacheService mutation (instant UI) + coordinator.enqueueSave(recordID)` → CKSyncEngine sends later. For deletes: capture the ScopedRecordIdentity BEFORE invalidating the cache row, then enqueueDelete — tombstone IDs must survive local deletion.

**Outbound:** engine requests batch → `RecordBridge` synthesizes current CKRecord from SwiftData, rehydrating stored changeTag + encodedSystemFields (optimistic locking). Dangling pending saves whose cache row vanished resolve fail-closed via `confirmedLocalDeletion` before converting save→delete. After successful send: persist ONLY the server-acked changeTag/encodedSystemFields. Never re-upsert sent record payloads.
- *Scope Correction Escape Hatch:* In `RecordBridge.validateScopedRecord`, a `QuestCompletionCache` row stored with `sourceDatabaseScope == "private"` is permitted to bridge to `.shared` ONLY when BOTH `familyRecordName` and `sourceZoneName` strictly match the expected family and zone. This is a sanctioned, tightly gated escape hatch for the "pending-review stall" (when a participant device records a completion before scope metadata fully resolves). Cross-family and cross-zone isolation remain strictly preserved by the preceding equality checks.

**Inbound (engine ingestion path):**
`CKRecord[] → ingest() → fail-closed guards → parse + scope validation → BackgroundCacheActor.batchUpsertParsedRecords (single-save batch commit) → accounting → optional sync notifications`.

Ingestion contract:
- Drop records when no active session OR caller zone ≠ active family zone (re-delivered later via persisted change tokens).
- Private (owner) and shared (participant) scopes ride the identical ingest() pipeline; the sole sanctioned exception is the non-owner reconciliation pass below.
- Cache reconciliation is a sanctioned second door that runs for EVERY device — owner and non-owner alike — at the end of each lifecycle sync pass. Triggers: bootstrap, foreground sync, manual sync, remote-notification sync, family-zone change, and network reconnect. Reconnect-triggered syncs are debounced: reconnect notifications arriving within a 45-second window coalesce into one pass (stamped under the coordinator's lifecycle Mutex), so connectivity flaps don't each fire the full snapshot query set. On every trigger, AppLifecycleCoordinator queries the family snapshot across thirteen record types — quests, ledger entries, quest completions, allowance periods, goals, profiles, quest templates, families, achievements, profile achievements, notification preferences, gem ledgers, reward events — round-trips the results to CKRecords, then branches on `appState.isZoneOwner`. The owner-side pass feeds the records through `CKSyncEngineDelegateHandler.handleIncomingRecordsDirectly` with `databaseScope == .private`, riding the standard ingest() pipeline (upsert-only, no prune). The non-owner pass feeds `BackgroundCacheActor.reconcileParticipantSet(records:validRecordNamesByType:familyRecordName:databaseScope:zoneID:)` with `databaseScope == .shared` directly instead of ingest(); records re-parse canonically on the main actor (`ParsedRecord.parse`, preserving changeTag + encodedSystemFields), then commit under SerialMutationQueue as ONE atomic upsert+prune pass — cached rows absent from the server-authoritative name sets are purged and exactly one saveContext() lands per pass, so @Query never observes a half-reconciled cache; a failed upsert or save leaves the context uncommitted and rows intact until the next pass. One fail-safe gates BOTH branches: an entirely empty snapshot — read as a scope that has not settled after fresh join or account recovery — aborts the pass instead of pruning the local cache. Reconciliation emits no sync notifications; any notifications these records warranted already fired on whichever device authored them.
- Any parse/cache-write failure marks the sync pass failed; freshness watermarks stamp ONLY after a full pass across all active scopes with zero failures.

**Conflicts:** serverRecordChanged → resolver applies frozen merge rules → merged result persists via single-record background batch carrying post-merge changeTag/encodedSystemFields; merged CKRecord returned for engine re-save.

**Payouts & savings engine:** `AllowancePeriod.status == .paid` is the atomic double-run skip-guard every trigger checks. `realTime` policy settles each completion immediately (credits totals WITHOUT closing the period); period closure happens only in `runPayout`. Within the payout cycle, after quest rewards settle: (1) net earnings split by child's current split percentages into buckets; (2) save-bucket portions flow into that bucket's FIFO goals; (3) monthly interest applies per config (deterministic ID guard); (4) long-term goal contributions trigger parent matching (capped if configured). Expired quests deactivate on week rollover.

**Hero Board:** quests with nil assignee are claimable; claim writes `claimedByProfileRecordName` + `claimedAt`. First claim wins via server conflict resolution; parents may revoke back to the board. No due-date logic applies.

**CSV import:** (`Project/Views/Treasury/LedgerImportView.swift` + `LedgerImportViewModel` → `LedgerImportService` deterministic `import-{rowContentHash}` flow): parse best-effort into staging rows → parent edits/assigns Purchased By → explicit confirmation creates ledger entries with deterministic `import-{rowContentHash}` IDs (re-import idempotent). Nothing touches the ledger pre-confirmation; unassigned rows block finalization rather than guessing. `LedgerImportView` observes `LedgerEntryCache` via `@Query` filtered on `recordName` prefix `import-` for instant post-import counts, and `LedgerImportViewModel.finalize()` triggers `sendPendingChanges()` post-upsert so CloudKit sync fires without waiting for a parent-list refresh. The former `Project/Views/Guild/LedgerImportView.swift` path is obsolete (duplicate removed; Treasury is canonical).

**State management:** SwiftUI `@Query` + `@Observable` ViewModels; no external state libraries. Sync triggers centralized in AppLifecycleCoordinator — never ad-hoc from views.

**Account/zone invalidation:** accountChange or family-zone change resets engines and purges that family's cache rows on the background actor.

## 5. Cross-Cutting Concerns

**Authentication/Authorization:**
- Session = device-local UserDefaults keys; recovery is discovery-driven (private zones first, then shared; hero match requires iCloudUserID equality — fail-closed).
- Identity Dedupe Contract: one iCloud user + one family = one Profile. Owner key = server-stamped Family.creatorUserRecordName. Dedupe lookups are fail-closed. Existing inactive matches reactivate, never duplicate.
- Identity caching is scoped to onboarding dedupe ONLY; `isFamilyOwner` re-resolves fresh every call.
- Client-side role checks are defense-in-depth only; see Authorization Model below.

**Error handling:** CloudKit calls retry with backoff [0.5s, 1.5s, 4s], max 3; failures surface as CloudKitServiceError. Sync-pass failures suppress freshness stamping rather than throwing. Ingestion drops log warnings and rely on token re-delivery.

**Push & background:** silent-push subscriptions per zone/database registered at zone setup; APNs wake routes through AppDelegate → lifecycle coordinator → delta fetch. Foreground catch-up uses freshness watermarks.

**Migrations:** any backfill registers a versioned MigrationStep on DataMigrationsCoordinator. Never patch records ad-hoc inside services. Incompatible SwiftData schema changes trigger automatic destructive cache reset + CKSyncEngine rehydration.

**Testing:** production app has NO mock layer — unit tests inject MockCloudKitService explicitly as protocol doubles; TestEnvironment gates only in-memory cache, engine instantiation skip, and seed data. Tests exercising ingestion must establish an active session first. Deterministic-ID money flows get dedicated double-run/idempotency tests (interest, match, transfer, import).

**UI — decimal pad dismissal (cross-cutting write-time convention):** Every `TextField` using `.keyboardType(.decimalPad)` must provide a keyboard dismissal path. Pattern: `@FocusState private var isAmountFocused: Bool` on the view, `.focused($isAmountFocused)` on the `TextField`, and applying `View.decimalPadDoneToolbar(isFocused: $isAmountFocused)` from `Project/Views/Shared/DecimalPadDismissModifier.swift`. Implementation uses `.safeAreaInset(edge: .bottom)` anchored to `isFocused.wrappedValue` with `.scrollDismissesKeyboard(.interactively)` to host an interactive Done button. UIKit's `ToolbarItemGroup(placement: .keyboard)` / `inputAccessoryView` is intentionally avoided because it generates non-finite frame dimension layout runtime faults (`Invalid frame dimension`) during sheet animations and keyboard transitions. This is a write-time convention — apply `decimalPadDoneToolbar(isFocused:)` when adding any new decimalPad field.

**UI — iCloud diagnostics visibility (prod-safe subset):** `iCloudStatusView` ships a prod-safe subset unconditionally in Release — cached record counts (all `*Cache` types scoped to the active family), `pendingUploadCount`, `lastSyncedAt` (relative), and sync status — so parents can self-triage sync health without Debug builds. Heavy diagnostics (engine state `private`/`shared`, per-scope freshness chips `✅/❌` per `CachedRecordType`, push/reconnect debounce ages, absolute timestamps, and `syncError` detail) remain gated behind `#if DEBUG` (`debugSyncHealthSection`). The `View` struct itself is unconditional, but the expensive debug overlay is compile-time excluded from Release. Do not re-wrap the entire view in `#if DEBUG`.

## 6. Agent Rules & Anti-Patterns

DO:
- Read/write data exclusively through `*Cache` models; convert to domain structs only at service/mutation boundaries.
- Route EVERY engine-delivered and query-derived server→cache write through `ingest(...)` — sanctioned exceptions: the non-owner reconciliation door (`reconcileParticipantSet`, §4; the owner-side §4 pass rides ingest() via `handleIncomingRecordsDirectly`) and FamilyService pre-session bootstrap mirrors (ingest fails closed before session establishment).
- Enforce family scoping in the fetch itself (predicate/index level).
- Capture delete identities before cache invalidation.
- Persist changeTag always; encodedSystemFields whenever writing a server-sourced snapshot.
- Add new notification/event types to NotificationEventType rather than hardcoding strings.
- Establish active session in tests before seeding records through ingestion paths.
- Use deterministic IDs for ALL money-movement records; verify double-run safety in tests.
- Gate RPG-era surfaces behind `FeatureFlags.rpgImmersive`; keep them compiling.

DON'T:
- Don't call CKDatabase/cloudKitService methods from Views or ViewModels — add a cache-first service method instead.
- Don't write query results directly into CacheService/BackgroundCacheActor outside `ingest()` or the sanctioned doors: non-owner reconciliation (`reconcileParticipantSet`, §4) and FamilyService pre-session bootstrap mirrors.
- Don't re-upsert sent records after successful sends; only refresh their system fields.
- Don't alter conflict merge formulas, XP ledger semantics, or watermark stamping conditions without explicit architecture review.
- Don't put authoritative domain state in UserDefaults.
- Don't reference planning artifacts (session IDs, task IDs, tickets) in code comments.
- Don't add week math, currency formatting, or rarity derivation anywhere other than WeekMath / CurrencyFormatter / QuestRarity.
- Don't delete RPG-era models/services/data "while cleaning up" — they are intentionally retained behind the flag.
- Don't render level/rarity/gem/gear/mascot UI while the RPG layer is flagged off.

## 7. Comment Policy

Code should be self-documenting: clear naming and structure over commentary. Comments explain WHY, not WHAT.
- Every new file gets the standard Xcode header (file name, project, author, date).
- Comment only genuinely non-obvious logic: edge cases, concurrency workarounds, CloudKit quirks.
- One-liners preferred; if a block needs a paragraph, refactor the code instead.
- Never reference planning sessions, tasks, PRs, or AI tooling in comments — describe domain behavior directly.

---

## CloudKit Share Permission (load-bearing — do not change)

`CKShare.publicPermission` is set to `.none` on every share-mint path — `CloudKitService.createShare(for:role:)` and `fetchOrCreateShare(for:role:)`. This is **REQUIRED**, not a misconfiguration:

- The public share link is **not** a family-join mechanism; it carries no membership grant. A user joins only after the Guild Master adds them as an explicit `.readWrite` participant via `UICloudSharingController` (Apple Messages invite). The share URL is therefore not a bearer credential — there is no public link to leak or rotate.
- Every added participant joins as `.readWrite`, so Hero/Ranger writes work identically to non-owner paths.
- Role-targeted invitations are minted as distinct `CKShare` records against the same family root, one per role. Titles follow `"<familyName>: Hero Invitation"` / `"<familyName>: Co-Parent Invitation"` (`UserRole.shareTitleSuffix`); `fetchOrCreateShare(for:role:)` reuses an existing role-matching share or mints a new one.
- At accept time the joiner's role is decoded from the share's title (`UserRole.fromShareTitle`); an unrecognized title falls back to `.hero` — recoverable, since the Guild Master can re-issue a role-targeted invite.
- Role-based rules are enforced client-side only; CloudKit provides no server-side business-rule validation. See Authorization Model below.

**Do not "fix" the `.none` permission thinking it breaks hero writes, do not add a public join link, and do not remove role decoding from share titles.**

---

## Authorization Model

Privileged mutations — role changes, member removal, payout finalization, quest verification, interest/match configuration, ledger export/import — are enforced at the service layer by verifying the acting profile's role (parent role) before mutating; unauthorized callers get `FamilyServiceError.unauthorized`. This is defense-in-depth against in-app callers.

It does **not** by itself stop a malicious CloudKit participant from forging raw `CKRecord` writes directly into the shared zone. The owner anchor hardens the highest-privilege, irreversible operations; reward minting and other remaining client-side operations are documented accepted residual risk.

### Authorization owner anchor

The `Profile.role` field alone is forgeable. The highest-privilege, irreversible family operations are anchored on the **server-authenticated CloudKit identity**:

- **`Family.creatorUserRecordName`** mirrors CloudKit's server-stamped, read-only `CKRecord.creatorUserRecordID`. Decoded **only** on the read path; **never authored locally**. Mirrored into `FamilyCache` for cache-first reads.
- **Irreversible owner-gated operations** — `deleteFamilyAndReset`, `updateMemberRole`, `kickMember` — require the server-authenticated user to equal the family creator (`isFamilyOwner`), evaluated fresh at enforcement time. Deny-by-default when unresolved.
- **Reversible owner-OR-parent operations** — `updateFamilyName`, `updatePayoutPolicy`, `updatePayoutDay` — remain available to any parent or the owner anchor, guarded by `ActiveFamilyScopeGuard`.
- **Legacy fallback:** families predating the anchor fall back to parent-role checks.
- **Profile self-service operations** gate on self/Parent only and are not owner-anchored. Child bucket transfers gate on self-ownership.

**Accepted residual risk:** reward minting (quest verify/reject, `runPayout`, `applyReward`, interest/match crediting) runs client-side and remains forgeable by a joined participant; fully closing it requires a server-side validation layer. The blast radius is a post-join participant forging `Profile.role`, against which the immutable owner anchor defends the irreversible operations above.

---

## Security Audit: Accepted Risk Register (non-findings)

This register codifies deliberate, load-bearing security decisions that are **accepted risk**, not defects. The security-audit gate must classify findings that merely restate the blast radius of an entry in this register — without introducing a new, concrete, in-scope exploit or a concrete alternative design — as **non-findings** and must NOT fail the build on them.

### AR-001 — Private shares with explicit participants (current model)

**Location:** `CloudKitService+Sharing.swift` — all share-mint paths set `share.publicPermission = .none`.

**Status:** Current, intentional design.

- There is no public bearer link: joining happens only via explicit per-participant invites added by the Guild Master through `UICloudSharingController`. No link exists to leak or rotate.
- Role-targeted invites are distinct `CKShare` records titled with `UserRole.shareTitleSuffix`; roles decode at accept time via `UserRole.fromShareTitle`. Participants join `.readWrite` so non-owner writes work fully.

**Remaining residual risk:** a legitimately joined participant can still forge the client-side `Profile.role` field; the immutable `creatorUserRecordName` owner anchor defends the irreversible operations. See AR-002.

**Security-audit directive:** A finding that merely restates the post-join role-forgery blast radius of the private-share model WITHOUT introducing a new, concrete, in-scope exploit OR a concrete design change must be classified as a NON-FINDING and must NOT fail the gate. Findings proposing to restore `publicPermission = .readWrite` or a public join URL contradict this register.

### AR-002 — Local auth is client-side only; CloudKit provides no server-side business-rule validation

**Status:** ACCEPTED (documented, defense-in-depth only).

Authenticated write-gating happens in the service layer (client-side role checks) plus the `creatorUserRecordName` owner anchor for the highest-privilege operations, as documented in the Authorization Model. This extends to client-side interest/match crediting under the deterministic-ID scheme.

**Security-audit directive:** This is an accepted residual risk; do not fail the gate on the absence of a server unless a concrete in-scope vulnerability is shown.

### AR-003 — Server-wins conflict resolution for secondary records

**Status:** ACCEPTED (intentional design).

Conflict resolution in `CKSyncConflictResolver` applies dedicated field/additive merges for core mutable records (`Quest`, `Profile`, `QuestCompletion`, `AllowancePeriod`). For secondary records (`LedgerEntry`, `Goal`, `GemLedger`, `RewardEvent`, `Achievement`, `ProfileAchievement`, `NotificationPreference`, `Family`), conflict resolution adopts the server record into cache on conflict (`serverRecordChanged`). All money-movement and credit records rely on deterministic record IDs (`contrib-*`, `interest-*`, `reward-*`, `transfer-*`, `import-*`) to prevent concurrent write collisions.

**Security-audit directive:** Server-wins conflict resolution for secondary records is accepted risk and intentional; do not classify the absence of multi-device client-wins field merging for secondary entities as a defect.

### AR-004 — Event-Driven / Token-Based Freshness (hydration token authority, clock-skew eliminated)

**Location:** `Project/Services/CacheService.swift:isCacheAuthoritative` now checks `isCacheFresh` existence only.

**Status:** ACCEPTED (intentional design, mitigated).

- Hydration is stamped in `CKSyncEngineCoordinator.completeSyncPass()` / `stampFreshness(for:scopes:)` after a successful fetch across active scopes with zero parse/cache-write failures.
- Invalidation occurs only via explicit events: `CKSyncConflictResolver` server-wins revert, `CKSyncEngineDelegateHandler` fetch/zone failure, and family purge/sign-out/zone switch.
- Blast radius: hydrated cache is authoritative regardless of device clock movement (+/- any interval); forward/backward skew no longer forces stale or masks staleness. Prior wall-clock TTL rationale and the `interval >= 0` guard are retired.

**Security-audit directive:** A finding that merely restates the clock-skew blast radius WITHOUT introducing a new, concrete, in-scope exploit must be classified as a NON-FINDING and must NOT fail the gate, because skew is eliminated under the hydration-token model.
