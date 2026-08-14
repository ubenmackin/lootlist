# Wishlist

> Wishlist for V2+ items deferred from the Ranger-onboarding V2-mode-A plan. Each item is independently shippable; do not bundle into a future feature plan without its own blueprint.

## Table of Contents

1. [Per-Zone Split for Heroes (Real Role Anchorability at CloudKit Layer)](#1-per-zone-split-for-heroes-real-role-anchorability-at-cloudkit-layer)
2. [Family-Switcher UX for Multi-Family Support](#2-family-switcher-ux-for-multi-family-support)
3. [FinanceKit Integration for Reward Minting (Closes the Forgeable Reward Minting Risk)](#3-financekit-integration-for-reward-minting-closes-the-forgeable-reward-minting-risk)
4. [removeParticipant Edge Cases (V2-mode-A Residual Risks)](#4-removeparticipant-edge-cases-v2-mode-a-residual-risks)
5. [Immutable Creator Anchor vs Transfer Guild Master](#5-immutable-creator-anchor-vs-transfer-guild-master)
6. [Inventory of ARCHITECTURE.md Updates Needed Post-V2-mode-A Implementation](#6-inventory-of-architecturemd-updates-needed-post-v2-mode-a-implementation)
7. [Post-V2-mode-A Rollout Validation (USER TESTING TRACKING)](#7-post-v2-mode-a-rollout-validation-user-testing-tracking)

---

## 1. Per-Zone Split for Heroes (Real Role Anchorability at CloudKit Layer)

**Summary:** CloudKit enforces permission PER-ZONE, not per-record-type. Today all participants (Hero + Ranger) live on the same family zone with `.readWrite`, so role distinction is a forgeable `Profile.role` field — an accepted residual risk. The real fix is one `CKShare`/zone per Hero: the Hero writes their own records in their own zone, while the Guild Master and any Rangers receive a `.readOnly` share of each per-Hero zone. Role distinction then becomes ENFORCED at the CloudKit zone-permission layer instead of being a client-side convention. This is a substantial rearchitecture — a new zone layout, shares-per-Hero, and a forked join flow in the sync logic — and was explicitly deferred from the V2-mode-A Ranger-onboarding plan.

**Status:** GREENFIELD, SPEC-ONLY.

## 2. Family-Switcher UX for Multi-Family Support

**Summary:** The dedupe backend already allows one iCloud user to belong to multiple families (dedupe is keyed on `iCloudUserID` + `family`), but the UI forces logout + re-entering a share URL to switch families. The real-world use case is divorced parents running different chore sets in different households. The backend support is foundational-but-invisible; surfacing a family-switcher UI is the V2 ask.

**Status:** BACKEND-SUPPORTED, UI-GREENFIELD.

## 3. FinanceKit Integration for Reward Minting (Closes the Forgeable Reward Minting Risk)

**Summary:** The V2 plan continues to mention FinanceKit reward integration. The current plan realizes one half of V2 (per-participant invites); the other half — FinanceKit reward minting to replace the forgeable client-side reward path — remains deferred. Once integrated, the accepted residual risk of forgeable reward minting closes. Reference: cf. §Authorization owner anchor + AR-002 in ARCHITECTURE.md.

**Status:** GREENFIELD, SPEC-ONLY.

## 4. removeParticipant Edge Cases (V2-mode-A Residual Risks)

**Summary:** With V2-mode-A, `CKShare.remove(participant:)` provides real revocation, closing the sticky-share concern. Residual edge cases may still surface during user testing: a stale local `share.participants` cache, server propagation delays, and participant-removal races with concurrent writes. The implementation plan ships basic `removeParticipant` integration in `kickMember`; further edge-case hardening — re-syncing share participants after removal, retry/backoff, and similar — is logged here.

**Status:** PARTIAL in plan, FULL hardening deferred.

## 5. Immutable Creator Anchor vs Transfer Guild Master

**Summary:** `Family.creatorUserRecordName` mirrors `CKRecord.creatorUserRecordID`, which CloudKit server-stamps at record-creation time and is immutable. The existing "Transfer Guild Master" per-member role menu call only performs a local `Profile.role` swap; the original creator retains the irreversible-op authorization (`deleteFamily`, `updateMemberRole`, `kickMember`) per the §Authorization owner anchor. This may be a design surprise — a "transferred" Guild Master who expects full ownership rights does not have them, because the immutable creator stamp never moves. Possible V2 paths: an explicit "true transfer" flow that re-creates the Family record under the new owner's account, OR documenting the local-only transfer behavior as accepted.

**Status:** SPEC-REVIEW needed.

## 6. Inventory of ARCHITECTURE.md Updates Needed Post-V2-mode-A Implementation

**Summary:** ~~After the Ranger-onboarding plan lands AND user testing confirms the V2 private-share model holds, the following ARCHITECTURE.md sections need a rewrite to reflect the new architecture. Per the Lead Architect POST-BLUEPRINT STEWARDSHIP policy, this rewrite should happen as a separate refinement pass — NOT bundled into the implementation plan.~~ **COMPLETED.** The ARCHITECTURE.md rewrite was bound into the implementation plan (required by the Stage-5 review gate rather than deferred to a separate refinement pass). The document is now consistent with the landed V2-mode-A code, and the user-testing-validation milestone no longer blocks the doc update; items observed during user testing may still surface follow-up corrections, but nothing in the checklist below is outstanding.

- **§1 CloudKit Ownership Model** — ~~currently references `publicPermission = .readWrite` as required for Hero writes~~ → **DONE:** rewritten to describe per-participant writes (Hero/Ranger added as `.readWrite` participants via `UICloudSharingController`) working identically.
- **§9 Onboarding Flow ASCII diagram** — ~~currently shows the "I'm a Parent / I'm a Hero + share URL" path~~ → **DONE:** rewritten to reflect the collapsed "Create a Family / Join a Family" + Waiting-screen + Apple-Messages-invite flow.
- **## CloudKit Share Permission (load-bearing — do not change) section** — ~~describes the now-retired `publicPermission = .readWrite` bearer model~~ → **DONE:** rewritten to describe the new `publicPermission = .none` private-share + per-participant-invite model, plus the role-titles-on-shares encoding (Hero Invitation / Co-Parent Invitation).
- **AR-001** — ~~currently labeled "ACCEPTED (load-bearing; do not alter)" with the closure note "until V2 replaces it."~~ → **DONE:** rewritten to "RESOLVED via V2-mode-A per-participant invites" with the design summary attached. AR-002 stays an accepted residual risk (forgeable reward minting) until FinanceKit integration (item #3 above).
- **§Authorization owner anchor** — ~~currently references the accepted residual risk text mentioning the public `readWrite` bearer link~~ → **DONE:** rewritten to reflect that the join-gate is now at the CloudKit layer (private share + GM-must-invite), shrinking the residual risk surface to "role field forgeable post-join, against which the immutable owner anchor continues to defend irreversible ops."

**Status:** **DONE** — completed as part of the implementation plan (review-gate requirement), not a separate refinement pass. The user-testing-confirmed-V2-model-holds milestone no longer blocks the document update.

## 7. Post-V2-mode-A Rollout Validation (USER TESTING TRACKING)

**Summary:** Per the user's request, the orchestrator holds at Stage 5 (Reviewer APPROVED) and does NOT auto-transition to Stage 6 (Release Manager). User testing happens next. The specific items to verify during user testing on a REAL device (not just the simulator):

- **Apple-Messages-invite arrival end-to-end:** GM taps "Invite Members" → role-picker → `UICloudSharingController` → Messages invite → joiner taps → app wakes → `onOpenURL` → `container.shareMetadata(for:)` → `pendingShareMetadata` → `acceptShare` → family appears in the joiner's `sharedCloudDatabase`. Verify across both Hero and Ranger role-pick paths.
- **shareTitle propagation:** verify `metadata.shareTitle` carries the role token end-to-end (the `:Hero Invitation` / `:Co-Parent Invitation` suffixes). If `shareTitle` is unreliable on certain iOS versions, log the failure, apply the `.hero` fallback, and consider an alternative role-token channel.
- **removeParticipant behavior:** kick a member via the per-member role menu (GM-side) and verify they stop receiving shared-zone writes — real revocation confirmed.
- **Multi-share-per-root-record:** verify both the Hero-share and the Co-Parent-share mint against the same family root record successfully (the CKShare multi-share model assumption). If rejected, a dummy-anchor fallback needs re-evaluation.
- **DetectedHero reconnect path:** verify the alt-Hero entry path still works after V2 (it should be preserved).
- **sign-out → rediscover:** verify the flow still recovers both the GM (private zones) and Hero/Ranger (shared zones) sessions correctly.

**Status:** PENDING — this is the tracking list for the user-testing phase that gates the ARCHITECTURE.md update pass in item #6.