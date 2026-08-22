# ARCHITECTURE.md — Loot List

## 1. System Overview & Intent

A family chore-and-allowance tracker for iOS, themed as fantasy RPG: parents ("Guild Masters") assign quests; kids ("Heroes") complete them to earn real local currency (never fictional gold). Data lives in a CloudKit custom zone shared via `CKShare`; a local SwiftData cache is the immediate UI source of truth and CloudKit is the cloud system of record. RPG vocabulary is mandatory in all user-facing copy except money, which is always rendered as real region currency via `CurrencyFormatter` — never hardcoded symbols, never "gold" copy.

Domain rules agents must not misinterpret:
- Roles: Guild Master (owner, private DB) / Ranger (co-parent) / Hero (participant, shared DB). Role drives which database every operation targets.
- Quest approval: `ApprovalMode` (`.autoApprove` default / `.parentVerify`) set per `QuestTemplate` or per quest. Completions transition `.pending → verified/rejected/withdrawn`; parent notifications fire on `.pending`.
- `Quest.rarity` is derived from XP (`QuestRarity.from(xp:)`), never stored.
- Week cycles are payout-day-aware half-open `[start, end)` ranges owned exclusively by `WeekMath`. Never compute week boundaries elsewhere. Effective payout day resolves profile override → family → `.sunday`.
- XP-credit idempotency is structural: `QuestCompletion.xpCredited` (optional Int) marks a completion as already credited; credits are recorded as immutable `RewardEvent`s with DETERMINISTIC IDs (`reward-{completionID}`) so CloudKit dedupes across devices. Never switch these to random UUIDs — that reintroduces double XP minting.
- Trophy requirement text is computed at render time from values; stored description text may be stale on legacy records.
- Internal identifiers keep legacy `gold` prefixes (`goldReward`, `Color.gold`, …). Do not rename them.
- Achievements: `AchievementService.AchievementRequirement` implements the V1 product spec (12 trophies) and must stay in sync with it.

## 2. Core Tech Stack & Constraints

- Swift 6.0 strict concurrency, SwiftUI, iOS 26+ minimum. XcodeGen builds the project. Container: `iCloud.com.volcrypt.lootlist`.
- Persistence: SwiftData cache schema `LootListSchemaV7` (`VersionedSchema`) + CloudKit via native `CKSyncEngine`.
- Strict constraints:
  - Views/ViewModels NEVER call CloudKit directly or hold raw `CKRecord`s/domain structs for presentation. All reads are `@Query` on `*Cache` models.
  - All mutations go through Services → `CacheService` write + `CKSyncEngineCoordinator.enqueueSave/enqueueDelete`.
  - All server→cache record writes ride ONE entry point: `CKSyncEngineDelegateHandler.ingest(records:databaseScope:zoneID:notifiesOnCompletion:)`. Never query-then-upsert directly into cache.
  - Every `*Cache` row is family-scoped (`FamilyScopedCache`, composite index familyRecordName + recordName). Cross-family isolation enforced at fetch/store layer, not downstream filtering.
  - Conflict merge semantics are FROZEN: quest banked XP max-merge capped at xpReward; Profile XP additive vs lastSyncedXP baseline with max-floor fallback; xpCredited non-nil preserve; server-authoritative status fields with client-wins display overlays. Changes require architecture review.
  - Services and AppState depend on `any CloudKitServiceProtocol` (narrower seams exist where useful: `CloudKitServicing` beside XPService, the `SpendingService` protocol for the manual→FinanceKit swap). Do not concrete-type CloudKit dependencies.
  - UserDefaults is device-local only: session keys, abandoned-zone queue, migration flags, freshness watermarks. NEVER authoritative cross-device domain data (balances, counters, credits).

## 3. Directory Structure & Component Roles

```
Project/
├── App/            # @main, AppState (auth state machine + session persistence),
│                   # AppDelegate (APNs), AppLifecycleCoordinator (ALL sync/payout/
│                   # migration triggers centralized here; single-flight state)
├── Models/
│   ├── CloudKit/   # Domain structs mirroring CKRecords (wire types)
│   ├── Local/      # SwiftData *Cache @Models, FamilyScopedCache protocol,
│   │               # LootListSchema (VersionedSchema)
│   └── Enums/      # Typed enums incl. CachedRecordType (record type ↔ cache mapping)
├── Services/       # Business logic layer:
│   ├── CloudKitService(+extensions)  # DB selection, zones, shares, retry
│   ├── Quest/Treasury/Family/Gem/XP/Spending/Achievement/Notification/Equipment
│   ├── CacheService(+Fetches/+Invalidation)  # @MainActor SwiftData CRUD for 0ms UI
│   ├── BackgroundCacheActor  # @ModelActor, autosaveEnabled=false, ALL off-main
│   │                         # server→cache writes; SerialMutationQueue-linearized;
│   │                         # exactly one save per batch pass
│   ├── CKSyncEngineCoordinator     # @MainActor engine lifecycle, enqueue buffers,
│   │                               # state serialization, watermark stamping
│   ├── CKSyncEngineDelegateHandler # delegate events + ingest() single entry point
│   ├── CKSyncConflictResolver      # serverRecordChanged/deleted merges (frozen rules)
│   ├── RecordBridge                # SwiftData → CKRecord synthesis on demand
│   └── DataMigrationsCoordinator   # versioned MigrationStep runner
├── ViewModels/     # @Observable screen state; operate directly on *Cache models
├── Views/          # SwiftUI screens grouped by feature; Shared/ = cross-cutting components
└── Utilities/      # Constants, WeekMath, CurrencyFormatter, TestEnvironment
ProjectTests/       # Unit tests (MockCloudKitService/MockRecordStore injected doubles)
ProjectIntegrationTests/  # Live CloudKit, Development env only, self-cleaning test zones
```

Where new files go: sync-engine code in `Services/`, lifecycle in `App/`, new cached entity models in `Models/Local/` (+ enum in `Models/Enums/`), screen code under its feature folder in `Views/`.

Adding a new cached record type REQUIRES all of: `*Cache` @Model conforming `FamilyScopedCache` with composite index; a `CachedRecordType` case; decode/init path in `CacheConversions`; upsert/fetch/invalidate helpers on CacheService; write-through in owning service; ingestion coverage via the pipeline.

## 4. Data Flow & Lifecycle

**Reads:** `@Query(*Cache)` → view/ViewModel. Family-scoped views filter at init via predicate-bound queries. Offline-safe by construction. Notification preferences read SwiftData cache-first; the UserDefaults bool is a cold-start-only subordinate fallback.

**Writes (local-first):**
`View action → Service → CacheService mutation (instant UI) + coordinator.enqueueSave(recordID)` → CKSyncEngine sends later. For deletes: capture the ScopedRecordIdentity BEFORE invalidating the cache row, then enqueueDelete — tombstone IDs must survive local deletion.

**Outbound:** engine requests batch → `RecordBridge` synthesizes current CKRecord from SwiftData, rehydrating stored changeTag + encodedSystemFields (optimistic locking). Dangling pending saves whose cache row vanished resolve fail-closed via `confirmedLocalDeletion` (absence proven across ALL tables) before converting save→delete. After successful send: persist ONLY the server-acked changeTag/encodedSystemFields (`BackgroundCacheActor.updateSystemFields`). Never re-upsert sent record payloads.

**Inbound (single ingestion path):**
`CKRecord[] → ingest() → fail-closed guards → BackgroundCacheActor.parseAndUpsert (parse + scope validation off-main) → single-save batch commit → ParseOutcome accounting → optional sync notifications`.

Ingestion contract:
- Drop records when no active session OR caller zone ≠ active family zone (re-delivered later via persisted change tokens).
- Both private (owner) and shared (participant) scopes use the identical pipeline.
- Participant reconciliation (lifecycle-triggered shared-DB hydration) converts queried records via toRecord() and feeds ingest() with notifiesOnCompletion=false (hydration is not a user-actionable event).
- Any parse/cache-write failure marks the sync pass failed; freshness watermarks (`cache_fresh_<family>_<type>`) stamp ONLY after a full pass across all active scopes with zero failures.

**Conflicts:** serverRecordChanged → resolver applies frozen merge rules → merged result persists via single-record background batch carrying post-merge changeTag/encodedSystemFields; merged CKRecord returned for engine re-save.

**Payouts:** `AllowancePeriod.status == .paid` is the atomic double-run skip-guard every trigger checks. `realTime` policy settles each completion immediately (credits totals WITHOUT closing the period); period closure happens only in `runPayout`. Expired quests deactivate (`isActive = false`) on week rollover and drop out of primary views.

**State management:** SwiftUI `@Query` + `@Observable` ViewModels; no external state libraries. Sync triggers centralized in AppLifecycleCoordinator (bootstrap, scenePhase foreground, APNs push with 25s budget, manual sync, zone transitions) — never ad-hoc from views.

**Account/zone invalidation:** accountChange or family-zone change resets engines and purges that family's cache rows on the background actor (family row + all scoped types).

## 5. Cross-Cutting Concerns

**Authentication/Authorization:**
- Session = device-local UserDefaults keys; recovery is discovery-driven (private zones first, then shared; hero match requires iCloudUserID equality — fail-closed, never adopt arbitrary profiles).
- Identity Dedupe Contract: one iCloud user + one family = one Profile. Hero key = Profile.iCloudUserID scoped by family reference; owner key = server-stamped Family.creatorUserRecordName (never locally authored). Dedupe lookups are fail-closed: only PROVABLE absence may mint/reactivate — transient errors never fall through to minting. Existing inactive matches are reactivated, never duplicated.
- Identity caching is scoped to onboarding dedupe ONLY: `isFamilyOwner` re-resolves the current user record ID fresh on every call, so an iCloud account switch mid-session can never authorize against a stale identity. Do not "optimize" this into the cached path.
- Client-side role checks are defense-in-depth only; see Authorization Model below for the owner anchor and accepted residual risk.

**Error handling:** CloudKit calls retry with backoff [0.5s, 1.5s, 4s], max 3; failures surface as CloudKitServiceError. Sync-pass failures (parse/cache-write) suppress freshness stamping rather than throwing. Ingestion drops (fail-closed) log warnings and rely on token re-delivery.

**Push & background:** silent-push subscriptions per zone/database registered at zone setup; APNs wake routes through AppDelegate → lifecycle coordinator → delta fetch. Foreground catch-up uses freshness watermarks: stale types trigger CloudKit hydration before cache-first service reads.

**Migrations:** any backfill of existing records registers a versioned MigrationStep on DataMigrationsCoordinator. Never patch records ad-hoc inside services. Incompatible SwiftData schema changes trigger automatic destructive cache reset + CKSyncEngine rehydration from CloudKit.

**Testing:** production app has NO mock layer — unit tests inject MockCloudKitService explicitly as protocol doubles; TestEnvironment gates only in-memory cache, engine instantiation skip, and seed data inside the app. Tests exercising ingestion must establish an active session first (ingestion is fail-closed without one).

## 6. Agent Rules & Anti-Patterns

DO:
- Read/write data exclusively through `*Cache` models; convert to domain structs only at service/mutation boundaries.
- Route EVERY server→cache write (delta fetch, reconciliation, conflict result) through `ingest(...)`.
- Enforce family scoping in the fetch itself (predicate/index level).
- Capture delete identities before cache invalidation.
- Persist changeTag always; encodedSystemFields whenever writing a server-sourced snapshot.
- Add new notification/event types to NotificationEventType rather than hardcoding strings.
- Establish active session in tests before seeding records through ingestion paths.

DON'T:
- Don't call CKDatabase/cloudKitService methods from Views or ViewModels — even "just for a fallback." Add a cache-first service method instead (hydrate the cache row, don't re-enqueue server-originated saves).
- Don't write query results directly into CacheService/BackgroundCacheActor outside `ingest()` — this silently drops encodedSystemFields, bypasses conflict resolution, and can clobber unsynced edits.
- Don't re-upsert sent records after successful sends; only refresh their system fields.
- Don't parse incoming records on the main thread; parsing belongs inside BackgroundCacheActor.
- Don't alter conflict merge formulas, XP ledger semantics, or watermark stamping conditions without explicit architecture review.
- Don't put authoritative domain state in UserDefaults.
- Don't reference planning artifacts (session IDs, task IDs, tickets) in code comments.
- Don't add week math, currency formatting, or rarity derivation anywhere other than WeekMath / CurrencyFormatter / QuestRarity.

## 7. Comment Policy

Code should be self-documenting: clear naming and structure over commentary. Comments explain WHY, not WHAT.
- Every new file gets the standard Xcode header (file name, project, author, date).
- Comment only genuinely non-obvious logic: edge cases, concurrency workarounds, CloudKit quirks.
- One-liners preferred; if a block needs a paragraph, refactor the code instead.
- Never reference planning sessions, tasks, PRs, or AI tooling in comments — describe domain behavior directly.

---

## CloudKit Share Permission (load-bearing — do not change)

`CKShare.publicPermission` is set to `.none` on every share-mint path — `CloudKitService.createShare(for:)`, `createShare(for:role:)`, and `fetchOrCreateShare(for:role:)`. This is **REQUIRED**, not a misconfiguration:

- The public share link is **not** a family-join mechanism; it carries no membership grant. A user joins only after the Guild Master adds them as an explicit `.readWrite` participant via `UICloudSharingController` (Apple Messages invite). The share URL is therefore not a bearer credential — there is no public link to leak or rotate.
- Every added participant joins as `.readWrite`, so Hero/Ranger writes (profile save, quest completion, spending, payout) work identically to the retired public-link model — the app remains fully usable for non-owners.
- Role-targeted invitations are minted as distinct `CKShare` records against the same family root, one per role. Titles follow `"<familyName>: Hero Invitation"` / `"<familyName>: Co-Parent Invitation"` (`UserRole.shareTitleSuffix`); `fetchOrCreateShare(for:role:)` reuses an existing role-matching share or mints a new one.
- At accept time the joiner's role is decoded from the share's title (`UserRole.fromShareTitle`); an unrecognized or legacy family-name-only title falls back to `.hero` — recoverable, since the Guild Master can re-issue a role-targeted invite.
- Role-based rules are enforced client-side only; CloudKit provides no server-side business-rule validation. See Authorization Model below.

**Do not "fix" the `.none` permission thinking it breaks hero writes, do not add a public join link, and do not remove role decoding from share titles.** Prior agents broke hero access by changing these; heroes write through explicit `.readWrite` participation, exactly like owners.

---

## Authorization Model

Privileged mutations — role changes, member removal, payout finalization, quest verification — are enforced at the service layer by verifying the acting profile's role (parent role) before mutating; unauthorized callers get `FamilyServiceError.unauthorized`. This is defense-in-depth against in-app callers (deep links, shortcuts, accidental callers).

It does **not** by itself stop a malicious CloudKit participant from forging raw `CKRecord` writes directly into the shared zone. The owner anchor hardens the highest-privilege, irreversible operations (see below); reward minting and other remaining client-side operations are documented accepted residual risk.

### Authorization owner anchor

The `Profile.role` field alone is forgeable — a malicious participant who has joined the family can issue a raw `CKRecord` write creating a `Profile` with `role = .guildMaster` bound to their own iCloud user ID, and every parent-role guard would then pass. The highest-privilege, irreversible family operations are therefore anchored on the **server-authenticated CloudKit identity** rather than the forgeable role field:

- **`Family.creatorUserRecordName`** mirrors CloudKit's server-stamped, read-only `CKRecord.creatorUserRecordID`. It is decoded **only** on the read path (from `record.creatorUserRecordID?.recordName`) and is **never authored locally**: `toRecord()` does not write it, mirroring the `changeTag` precedent for server-owned fields. Because CloudKit controls the creator stamp (saves cannot spoof it), a participant cannot rewrite the anchor. Mirrored into `FamilyCache` for cache-first reads.
- **Irreversible owner-gated operations** — `deleteFamilyAndReset`, `updateMemberRole`, `kickMember` — require the server-authenticated user to equal the family creator (`isFamilyOwner`), evaluated fresh at enforcement time. Deny-by-default when the creator is unresolved (nil anchor never grants ownership).
- **Reversible owner-OR-parent operations** — `updateFamilyName`, `updatePayoutPolicy`, `updatePayoutDay` — remain available to any parent (Guild Master / Ranger) *or* the owner anchor, guarded by `ActiveFamilyScopeGuard`.
- **Legacy fallback:** families predating the anchor (nil `creatorUserRecordName`) fall back to parent-role checks (`zone-owner + parent-role` for `deleteFamilyAndReset`), keeping existing families functional without backfill.
- **Profile self-service operations** gate on self/Parent only and are not owner-anchored.

**Accepted residual risk:** reward minting (quest verify/reject, `runPayout`, `applyReward`) runs client-side and remains forgeable by a joined participant; fully closing it requires a server-side validation layer (FinanceKit integration remains deferred V2). The blast radius is a post-join participant forging `Profile.role`, against which the immutable owner anchor defends the irreversible operations above.

---

## Security Audit: Accepted Risk Register (non-findings)

This register codifies deliberate, load-bearing security decisions that are **accepted risk**, not defects. The security-audit gate must classify findings that merely restate the blast radius of an entry in this register — without introducing a new, concrete, in-scope exploit or a concrete alternative design — as **non-findings** and must NOT fail the build on them.

### AR-001 — Private shares with explicit participants (current model)

**Location:** `CloudKitService+Sharing.swift` — all share-mint paths set `share.publicPermission = .none`.

**Status:** Current, intentional design.

- There is no public bearer link: joining happens only via explicit per-participant invites added by the Guild Master through `UICloudSharingController`. No link exists to leak or rotate.
- Role-targeted invites are distinct `CKShare` records titled with `UserRole.shareTitleSuffix`; roles decode at accept time via `UserRole.fromShareTitle` (unknown titles fall back to `.hero`). Participants join `.readWrite` so non-owner writes work fully.

**Remaining residual risk:** a legitimately joined participant can still forge the client-side `Profile.role` field; the immutable `creatorUserRecordName` owner anchor defends the irreversible operations. See AR-002.

**Security-audit directive:** A finding that merely restates the post-join role-forgery blast radius of the private-share model WITHOUT introducing a new, concrete, in-scope exploit OR a concrete design change must be classified as a NON-FINDING (matches this register) and must NOT fail the gate. In particular, findings proposing to restore `publicPermission = .readWrite` or a public join URL contradict this register — the public bearer-link model was deliberately retired for security reasons.

### AR-002 — Local auth is client-side only; CloudKit provides no server-side business-rule validation

**Status:** ACCEPTED (documented, defense-in-depth only).

Authenticated write-gating happens in the service layer (client-side role checks) plus the `creatorUserRecordName` owner anchor for the highest-privilege operations, as documented in the Authorization Model.

**Security-audit directive:** This is an accepted residual risk; do not fail the gate on the absence of a server unless a concrete in-scope vulnerability is shown.