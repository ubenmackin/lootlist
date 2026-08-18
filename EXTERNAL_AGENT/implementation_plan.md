# LootList Gamification Overhaul — Implementation Plan

> **Turn a chore tracker that speaks RPG into an RPG that tracks chores.**

---

## Background & Design Principles

### Hero-Only Gamification Scope

All gamification features — pixel art, mascot, Gems, loot drops, journey map, celebrations, sound design — live **exclusively in the Hero (child) experience**. The parent side (Guild Master / Ranger) remains a clean, administrative management interface focused on quest assignment, approval, payouts, and family settings. Parents are the *game masters*, not the *players*.

| Experience | Audience | Character |
|---|---|---|
| **Hero UI** | Kids & Teens | Full RPG: pixel art avatar, mascot companion, Gem economy, loot drops, journey map, celebrations, sound effects, rarity effects |
| **Parent UI** | Guild Master & Ranger | Admin tool: quest management, approval queue, payout processing, family settings. Clean iOS-native design. No game chrome. |

The one exception is **Family Challenges** (Phase 5), where parents *create* guild-wide challenges — but even there, the parent sees a simple admin form while Heroes see the gamified "boss fight" presentation.

### Core Constraint: Real Money ≠ Game Currency
Allowance money is **real currency** (USD/locale). It must never be inflated by game mechanics. A new in-game currency called **Gems 💎** will be introduced for cosmetic/game-only rewards. The two economies are strictly separated:

| Currency | Source | Spent On | Display |
|---|---|---|---|
| **Money** (real) | Quest completion → parent-approved allowance | Real-world purchases (Scroll of Spending) | `$4.50` via `CurrencyFormatter` |
| **Gems** 💎 (virtual) | Loot drops, streaks, daily login, bonus objectives | Avatar equipment, accessories, themes, cosmetics | `💎 125` with gem icon |

> [!IMPORTANT]
> Gems are **never** exchangeable for real money. No "bonus money" appears from game mechanics. The two economies are firewalled.

### Consequences for Missed Tasks
- **No HP loss or punitive damage** — the real-money loss from missed allowance is consequence enough
- Missed tasks = **missed loot drops** (opportunity cost, not punishment)
- Streak breaks = lost multiplier bonus, but **Streak Shields** provide forgiveness
- The mascot looks disappointed but encouraging, never angry

### Per-Class Gameplay Differences
- **Back-burnered to V2** — class choice remains cosmetic for now
- The pixel art system is designed with class-specific sprites, so visual distinction is immediate
- Stat categories can be layered on later without rearchitecting

### Art Direction
- **32×32 pixel art sprites** rendered programmatically via SwiftUI Canvas
- **Palette-indexed** approach (8-16 colors per sprite) for efficient data encoding
- **Layered compositing**: body → class outfit → equipment → accessories
- **Simple frame animation**: 2-3 frame idle bounce, 3-4 frame celebration
- **Full replacement** of existing illustrated avatar presets — pixel art is the new default, legacy assets removed from the asset catalog

---

## Proposed Changes

### Phase 1: "Make It Feel Alive" — Visual Polish & Juice

> **Goal**: Without adding new game systems, make the existing app *feel* like a game through animation, sound, and visual feedback. Every interaction should produce satisfying feedback.

---

#### 1.1 XP Progress Bar on Hero Dashboard

The single most impactful change. Makes progression visible on the primary screen.

##### [MODIFY] [HeroHeaderCardView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Hero/HeroHeaderCardView.swift)

- Add `xpProgress: Double` (0.0–1.0), `currentLevel: Int`, `xpIntoLevel: Int`, `xpForNextLevel: Int` parameters
- Render an animated XP bar below the stats row:
  - Capsule track with gradient fill (blue → purple)
  - Level badge on the left: `Lv. 4`
  - XP text on the right: `127 / 200 XP`
  - Fill animates with `.spring()` when XP changes
  - Particle sparkle effect at the fill edge

##### [MODIFY] [HeroDashboardView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Hero/HeroDashboardView.swift)

- Compute `LevelProgress` from `XPService.levelProgress()` and pass to `HeroHeaderCardView`

---

#### 1.2 Level-Up Celebration Overlay

Reuse the existing `CelebrationManager` + `CelebrationOverlayView` pattern.

##### [MODIFY] [CelebrationManager.swift](file:///Users/kupan787/opencode/LootList/Project/Services/CelebrationManager.swift)

- Extend `CelebrationItem` with a `isLevelUp: Bool` flag and `oldLevel: Int` / `newLevel: Int` fields
- Add `enqueueLevelUp(oldLevel:newLevel:profile:)` method

##### [MODIFY] [CelebrationOverlayView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Shared/CelebrationOverlayView.swift)

- Add level-up variant rendering:
  - Shows old level → new level with animated counter
  - Displays new title (e.g., "You are now a Veteran!")
  - Different color scheme (blue/purple gradient vs. gold for trophies)
  - Same confetti + chime + haptic

##### [MODIFY] [XPService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/XPService.swift)

- After detecting `updated.level > oldLevel`, enqueue a level-up celebration via `CelebrationManager`
- Wire `CelebrationManager` as a dependency

---

#### 1.3 Quest Card Rarity Effects

Make quest rarity visually dramatic — Common should look plain, Legendary should glow.

##### [MODIFY] [QuestCardView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Hero/QuestCardView.swift)

- Add rarity-derived visual treatment:
  - **Common**: Standard card, no special treatment
  - **Rare**: Subtle blue-tinted border, `sparkles` icon badge
  - **Epic**: Purple shimmer border (animated gradient stroke), `star.fill` badge, slight background glow
  - **Legendary**: Animated gold border with pulsing glow effect, `crown.fill` badge, gold particle ambient effect
- Rarity badge pill in the top-right corner of the card showing rarity name + icon

##### [NEW] [RarityBorderModifier.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Shared/RarityBorderModifier.swift)

- Reusable `ViewModifier` that applies rarity-appropriate border effects
- Uses `TimelineView` for animated shimmer on Epic/Legendary
- Configurable: `.rarityBorder(.legendary)` modifier

---

#### 1.4 Quest Completion Micro-Animations

##### [MODIFY] [QuestCardView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Hero/QuestCardView.swift)

- On completion tap: checkbox morphs into a seal with a spring animation + scale overshoot
- Card briefly flashes green and shrinks slightly before settling
- Haptic: `UIImpactFeedbackGenerator(.medium)` on tap

##### [NEW] [QuestCompletionEffectView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Shared/QuestCompletionEffectView.swift)

- Overlay effect: "+25 XP" text floats up and fades out from the card
- Gold "+$1.50" text floats alongside if the quest has a monetary reward
- Small burst of 5-8 particles matching the rarity color

---

#### 1.5 Streak Badge Visual Escalation

##### [MODIFY] [StreakBadge.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Shared/StreakBadge.swift)

- Evolving flame appearance based on streak tier:
  - **1–2 days**: Small orange flame (current)
  - **3–6 days**: Medium flame with subtle animation (gentle sway)
  - **7–13 days**: Larger flame, red-to-orange gradient, slow pulse glow
  - **14–29 days**: Blue flame core with orange tips, continuous sway animation
  - **30+ days**: White-hot flame with particle embers, rainbow shimmer outline
- Each tier transition triggers a brief celebration toast

---

#### 1.6 Extended Sound Design

##### [NEW] [SoundManager.swift](file:///Users/kupan787/opencode/LootList/Project/Services/SoundManager.swift)

- Centralized audio manager wrapping `AudioServicesPlaySystemSound` + `AVAudioPlayer` for custom sounds
- Sound events enum: `.questComplete`, `.xpGain`, `.levelUp`, `.lootDrop`, `.gemEarned`, `.streakMilestone`, `.dailyLogin`, `.buttonTap`
- Haptic pairing: each sound event has a corresponding haptic pattern
- Respects existing `celebrationSoundEnabled` `@AppStorage` toggle
- Pitch randomization (±5%) on repetitive sounds to prevent auditory fatigue

---

#### 1.7 Quest Completion Flavor Text

##### [NEW] [FlavorTextProvider.swift](file:///Users/kupan787/opencode/LootList/Project/Utilities/FlavorTextProvider.swift)

- Static library of RPG-flavored completion messages, organized by quest rarity:
  - Common: `"Another task vanquished!"`, `"The kingdom thanks you."`, `"Well done, adventurer."`
  - Rare: `"A worthy challenge, conquered!"`, `"Your skills grow stronger."`
  - Epic: `"A legendary feat of bravery!"`, `"Tales will be told of this deed!"`
  - Legendary: `"THE REALM TREMBLES AT YOUR POWER!"`, `"You have achieved the impossible!"`
- Shown in the toast/overlay after quest submission
- Level-up messages: `"Your training has paid off. You are now a Veteran — a true warrior of the household."`

---

### Phase 2: "Make Progression Meaningful" — Gems Economy & Loot System

> **Goal**: Introduce the Gems 💎 in-game currency, random loot drops, daily rewards, and streak multipliers. This is where the app starts *feeling* like a game with variable rewards.

---

#### 2.1 Gems Currency — Data Model & Service

##### [NEW] CloudKit Record Type: `GemLedger`

New CloudKit record type tracking Gem transactions:

| Field | Type | Description |
|---|---|---|
| `profileRecordName` | `String` | Hero this ledger entry belongs to |
| `familyRecordName` | `String` | Family scope |
| `amount` | `Int64` | Gems earned (positive) or spent (negative) |
| `source` | `String` | Enum: `lootDrop`, `dailyLogin`, `streakBonus`, `challengeReward`, `shopPurchase` |
| `sourceDetail` | `String` | Optional context (e.g., quest name, item purchased) |
| `createdAt` | `Date` | Transaction timestamp |

##### [NEW] [GemLedger.swift](file:///Users/kupan787/opencode/LootList/Project/Models/CloudKit/GemLedger.swift)

- CloudKitRecord conformance with `toRecord()` / `init(record:)`
- Deterministic record naming: `gem-<profileID>-<timestamp>-<source>`

##### [NEW] [GemLedgerCache.swift](file:///Users/kupan787/opencode/LootList/Project/Models/Local/GemLedgerCache.swift)

- SwiftData `@Model` with family/profile index

##### [NEW] [GemService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/GemService.swift)

- `creditGems(_:to:source:detail:)` — add gems to a hero's balance
- `spendGems(_:from:on:)` — deduct gems for shop purchases
- `balance(for:)` — computed from cached ledger entries
- Idempotent: deterministic record IDs prevent double-crediting across devices

##### [MODIFY] [Profile.swift](file:///Users/kupan787/opencode/LootList/Project/Models/CloudKit/Profile.swift)

- Add `gems: Int` field (denormalized balance for fast display)
- Sync'd via CloudKit, authoritative balance computed from `GemLedger` entries

##### [MODIFY] [ProfileCache.swift](file:///Users/kupan787/opencode/LootList/Project/Models/Local/ProfileCache.swift)

- Add `gems: Int` cached field

##### Schema Migration

- [MODIFY] [LootListSchema.swift](file:///Users/kupan787/opencode/LootList/Project/Models/Local/LootListSchema.swift) — Add `LootListSchemaV7` with `GemLedgerCache` model, migration from V6

---

#### 2.2 Loot Drop System

##### [NEW] [LootDropService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/LootDropService.swift)

- Called after every successful quest completion
- **Drop rate logic**:
  - Base drop rate: **15%** for Common quests
  - Rare quests: **20%**
  - Epic quests: **30%**
  - Legendary quests: **50%**
  - Active streak multiplier: +2% per streak day (capped at +20%)
- **Drop table** (weighted random):
  - 60% chance: Small Gem pouch (5–15 💎)
  - 25% chance: Medium Gem pouch (20–40 💎)
  - 10% chance: Large Gem pouch (50–100 💎)
  - 5% chance: Equipment piece (cosmetic unlock for pixel art avatar)
- Returns a `LootDrop` struct with contents, presented via treasure chest animation

##### [NEW] [LootDropOverlayView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Shared/LootDropOverlayView.swift)

- Animated treasure chest that shakes, then opens with a burst of light
- Contents revealed with spring animation: Gem icon + count, or equipment preview
- Auto-dismisses after 4 seconds, tap to skip
- Sound: distinct "chest open" chime + Gem-earning jingle

##### [MODIFY] [QuestService+Completions.swift](file:///Users/kupan787/opencode/LootList/Project/Services/QuestService+Completions.swift)

- After a completion is approved (auto or parent-verified), call `LootDropService.rollForLoot()`
- If loot drops, credit Gems via `GemService` and enqueue the overlay

---

#### 2.3 Daily Login Reward

##### [NEW] [DailyLoginService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/DailyLoginService.swift)

- Tracks last login date via `@AppStorage("lastLoginDate")`
- 7-day reward cycle:
  - Day 1: 5 💎
  - Day 2: 10 💎
  - Day 3: 15 💎
  - Day 4: 20 💎
  - Day 5: 25 💎
  - Day 6: 30 💎
  - Day 7: 50 💎 + mystery bonus (small loot drop)
- Resets after Day 7 and repeats
- Shown as a treasure chest on the Hero Dashboard on first open of the day

##### [NEW] [DailyLoginBannerView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Hero/DailyLoginBannerView.swift)

- Compact card at the top of the quest board: "🎁 Daily Reward! Tap to claim"
- Shows the 7-day calendar with filled/empty circles
- Tapping triggers the Gem credit + animation

---

#### 2.4 Streak XP Multiplier & Streak Shields

##### [MODIFY] [XPService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/XPService.swift)

- Apply streak multiplier to XP earned from quest completions:
  - 1–2 day streak: 1.0× (no bonus)
  - 3–6 day streak: 1.1× XP
  - 7–13 day streak: 1.25× XP
  - 14–29 day streak: 1.5× XP
  - 30+ day streak: 2.0× XP
- Show bonus XP separately in the completion toast: "+25 XP (+6 streak bonus)"

##### Streak Shields

- Heroes earn 1 **Streak Shield** every 7 consecutive streak days
- A Streak Shield automatically activates if a day is missed, preserving the streak
- Shield inventory stored on `Profile` (new `streakShields: Int` field)
- Visual: shield icon next to the streak badge showing shield count

---

#### 2.5 NPC Mascot Companion & Daily Bonus Objectives

The mascot is a **guide and cheerleader**, not a task-giver. It never invents new chores — it only encourages the hero to complete the quests their parent has already assigned. Daily bonus objectives are meta-goals about *how* and *when* to tackle assigned work.

##### [NEW] [MascotCompanion.swift](file:///Users/kupan787/opencode/LootList/Project/Models/Enums/MascotCompanion.swift)

- User-selectable mascot enum:
  ```
  enum MascotCompanion: String, CaseIterable {
      case owl     // "Sage" — wise, bookish
      case dragon  // "Ember" — fierce, energetic
      case fairy   // "Pip" — cheerful, sparkly
      case fox     // "Scout" — clever, sneaky
      case cat     // "Whiskers" — chill, encouraging
  }
  ```
- Each mascot has: name, personality tagline, 32×32 pixel art sprite (idle + happy + sad + celebrating frames), contextual dialogue lines
- Selection stored on `Profile.mascotCompanion` (new field)
- Selection UI in the Profile tab alongside avatar customization

##### [NEW] [MascotSprites.swift](file:///Users/kupan787/opencode/LootList/Project/Resources/SpriteData/MascotSprites.swift)

- 5 mascot pixel art sprites (32×32) with animation frames:
  - **Idle**: 2 frames (gentle bounce/sway)
  - **Happy**: 2 frames (bouncing, sparkles — shown when quests are being completed)
  - **Encouraging**: 2 frames (waving, pointing — shown when quests are overdue)
  - **Celebrating**: 4 frames (jumping, confetti — shown on loot drops and level-ups)

##### [NEW] [BonusObjectiveService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/BonusObjectiveService.swift)

- Generates one daily **bonus objective** per hero, deterministically seeded by date + profile ID
- Bonus objectives are **meta-goals about completing parent-assigned quests**, never new tasks:
  - "Complete all of today's quests" → 20 💎
  - "Finish your first quest before noon" → 15 💎
  - "Keep your streak alive today" → 10 💎
  - "Complete every quest this week with none overdue" → 50 💎 (weekly)
- The mascot "delivers" the objective with a dialogue line:
  - Sage (owl): *"A wise hero finishes their quests early. Complete all of today's quests for a Gem bonus!"*
  - Ember (dragon): *"RAWR! Let's crush all of today's quests! Bonus Gems await!"*
- Stored locally only (not synced via CloudKit — these are ephemeral)
- Evaluation runs on `rebuildViewModel()` in the dashboard

##### [NEW] [MascotBannerView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Hero/MascotBannerView.swift)

- Compact card shown below the hero header card on the dashboard
- Mascot pixel art sprite on the left (animated idle/happy/encouraging based on quest state)
- Speech bubble with the daily bonus objective and Gem reward
- Progress indicator (e.g., "2/3 quests completed")
- Contextual mascot state:
  - **No quests done yet**: Mascot in idle pose, speech bubble shows today's bonus objective
  - **Making progress**: Mascot happy, "Keep going! 2 of 3 done!"
  - **Overdue quests**: Mascot encouraging (not angry), "You've got this! Don't let the Dust Monsters win!"
  - **All done**: Mascot celebrating, "Amazing work, hero! 🎉" + Gem reward animation
  - **Bonus already claimed**: Mascot happy, "Great job today! See you tomorrow!"
- Completion triggers a Gem credit + mascot celebration animation

---

### Phase 3: "Bring the Hero to Life" — Pixel Art Avatar System

> **Goal**: Fully replace the existing illustrated avatar presets with programmatic 32×32 pixel art sprites that visibly change with equipment and level. Legacy art assets will be removed from the asset catalog.

---

#### 3.1 Pixel Art Rendering Engine

##### [NEW] `Project/Views/PixelArt/` directory

###### [NEW] [PixelSprite.swift](file:///Users/kupan787/opencode/LootList/Project/Views/PixelArt/PixelSprite.swift)

- Core data model:
  ```
  struct PixelSprite: Sendable, Equatable {
      let width: Int       // 32
      let height: Int      // 32
      let palette: [Color] // 8-16 indexed colors
      let pixels: [UInt8]  // width × height, each byte = palette index (0 = transparent)
  }
  ```
- Compact encoding: each sprite is 1,024 bytes (32×32) + palette definition
- Static factory methods: `PixelSprite.knightBase`, `.mageBase`, etc.

###### [NEW] [PixelSpriteView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/PixelArt/PixelSpriteView.swift)

- SwiftUI `Canvas`-based renderer:
  - Each pixel = filled rectangle at `pixelSize` scale (e.g., 4pt per pixel = 128×128pt view)
  - Render from pre-composited `UIImage` for performance (generate once, cache)
  - Support for multiple sizes: `.small` (64pt), `.medium` (96pt), `.large` (128pt), `.xlarge` (192pt)

###### [NEW] [SpriteCompositor.swift](file:///Users/kupan787/opencode/LootList/Project/Views/PixelArt/SpriteCompositor.swift)

- Layered compositing engine:
  1. **Body layer**: Skin tone + base shape (shared across all classes)
  2. **Class outfit layer**: Knight armor, Mage robes, Rogue cloak, Guardian plate, Healer vestments
  3. **Equipment layer**: Helmet, weapon, shield, cape — unlocked via Gem Shop
  4. **Accessory layer**: Aura effects (sparkle, bolt, star, flame) — existing level-gated accessories now rendered as pixel overlays
- Composite method: iterate layers bottom-up, non-transparent pixels overwrite
- Cache composited result as `UIImage` keyed by `(class, equipment set, accessories)`

###### [NEW] [SpriteAnimator.swift](file:///Users/kupan787/opencode/LootList/Project/Views/PixelArt/SpriteAnimator.swift)

- Frame-based animation controller:
  - **Idle**: 2 frames, 1-pixel vertical bounce, 800ms cycle
  - **Celebration**: 4 frames, arms up + confetti particles, 400ms cycle, plays once
  - **Walking**: 4 frames, alternating legs, 300ms cycle (for journey map)
- Uses `TimelineView(.periodic(every: frameDuration))` to drive frame changes

---

#### 3.2 Sprite Data — All 20 Character Presets as Pixel Art

##### [NEW] `Project/Resources/SpriteData/` directory

###### [NEW] [KnightSprites.swift](file:///Users/kupan787/opencode/LootList/Project/Resources/SpriteData/KnightSprites.swift)
###### [NEW] [MageSprites.swift](file:///Users/kupan787/opencode/LootList/Project/Resources/SpriteData/MageSprites.swift)
###### [NEW] [RogueSprites.swift](file:///Users/kupan787/opencode/LootList/Project/Resources/SpriteData/RogueSprites.swift)
###### [NEW] [GuardianSprites.swift](file:///Users/kupan787/opencode/LootList/Project/Resources/SpriteData/GuardianSprites.swift)
###### [NEW] [HealerSprites.swift](file:///Users/kupan787/opencode/LootList/Project/Resources/SpriteData/HealerSprites.swift)

Each file defines 4 sprite variants per class (matching existing presets):
- 32×32 palette-indexed pixel arrays
- 2 idle animation frames per variant
- 4 celebration animation frames per variant
- Class-specific color palettes

###### [NEW] [EquipmentSprites.swift](file:///Users/kupan787/opencode/LootList/Project/Resources/SpriteData/EquipmentSprites.swift)

- Equipment overlay sprites (helmets, weapons, shields, capes)
- ~20 equipment items to start, gated behind Gem purchases
- Each item is a partial 32×32 sprite (mostly transparent) that composites onto the character

---

#### 3.3 Gem Shop — Equipment Store

##### [NEW] [GemShopView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Hero/GemShopView.swift)

- New screen accessible from the Hero Profile tab
- Grid of purchasable equipment items, each showing:
  - Pixel art preview of the item
  - Preview of character wearing it
  - Gem cost — **generous starting prices**: 💎 25 for basic items, 💎 100 for mid-tier, 💎 250 for rare, 💎 500 for legendary
  - Locked/owned state
- Purchase flow: confirm → deduct Gems → unlock item → equip immediately

##### [NEW] CloudKit Record Type: `OwnedEquipment`

| Field | Type | Description |
|---|---|---|
| `profileRecordName` | `String` | Hero who owns this |
| `familyRecordName` | `String` | Family scope |
| `equipmentID` | `String` | Equipment catalog identifier |
| `acquiredAt` | `Date` | When purchased/earned |
| `source` | `String` | `shopPurchase` or `lootDrop` |

##### [MODIFY] [Profile.swift](file:///Users/kupan787/opencode/LootList/Project/Models/CloudKit/Profile.swift)

- Add `equippedItems: [String]` — list of equipped equipment IDs (helmet, weapon, shield, cape slots)

##### [MODIFY] [AvatarService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/AvatarService.swift)

- `renderSpec()` now includes equipped items → `SpriteCompositor` uses them for layered rendering

##### Integration with existing avatar system

- The existing `AvatarPreset` enum maps 1:1 to base pixel sprites
- `ProfileAvatarView` detects if the profile has a pixel sprite available and renders `PixelSpriteView` instead of the current squircle image
- Custom photo avatars continue to work as-is (shown alongside the pixel sprite, or replacing it per user preference)

---

### Phase 4: "Give the Hero a World" — Journey Map

> **Goal**: A visual representation of the hero's lifetime journey. A winding path through themed zones, with the hero's pixel art avatar standing at their current position.

---

#### 4.1 Journey Map Data Model

##### [NEW] [JourneyZone.swift](file:///Users/kupan787/opencode/LootList/Project/Models/Enums/JourneyZone.swift)

```swift
enum JourneyZone: Int, CaseIterable {
    case startingMeadow    // Levels 1–5
    case denseForest       // Levels 6–10
    case mountainPass      // Levels 11–15
    case dragonsReach      // Levels 16–20
    case eternalRealm      // Levels 21+
}
```

- Each zone has: name, description, color palette, background pattern, milestone markers
- Zones are purely cosmetic — driven by current level

---

#### 4.2 Journey Map View

##### [NEW] [JourneyMapView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Hero/JourneyMapView.swift)

- Horizontally scrolling map rendered with SwiftUI Canvas
- Winding path with zone transitions marked by decorative gates/arches
- **Milestone markers** at each level (dots on the path, filled = reached)
- **Hero sprite** (32×32 pixel art, walking animation) positioned at current level
- **Zone art**: Simple pixel-art scene elements (trees for forest, rocks for mountains, etc.)
- **Auto-scroll** to hero's current position on appear
- **Tap milestone** to see level details (title, XP required, unlocks)

##### [NEW] [ZoneBackgroundRenderer.swift](file:///Users/kupan787/opencode/LootList/Project/Views/PixelArt/ZoneBackgroundRenderer.swift)

- Procedural pixel-art background tiles for each zone:
  - Meadow: green grass, flowers, blue sky
  - Forest: dark green trees, mushrooms, fog
  - Mountains: gray rocks, snow caps, eagles
  - Dragon's Reach: volcanic rock, lava, dark sky
  - Eternal Realm: celestial, stars, floating islands

##### Navigation Integration

- [MODIFY] [HeroDashboardView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Hero/HeroDashboardView.swift)
  - Add a prominent **Journey Map card** above the quest board on the Hero Dashboard
  - Card shows: current zone name, hero pixel art standing on the path, level progress bar, "Tap to explore" affordance
  - Tapping expands to a full-screen modal with the complete scrollable map
  - No changes to `TabBarView` — the tab bar stays at 4 Hero tabs

---

### Phase 5: "Make It Social" — Family & Guild Mechanics

> **Goal**: Transform the family from isolated players into a cooperative guild with shared goals.

---

#### 5.1 Family Quest Board (Guild Challenges)

##### [NEW] CloudKit Record Type: `FamilyChallenge`

| Field | Type | Description |
|---|---|---|
| `familyRecordName` | `String` | Family scope |
| `title` | `String` | "Everyone completes all quests this week" |
| `description` | `String` | Flavor text |
| `rewardGems` | `Int64` | Gem reward per hero on completion |
| `targetType` | `String` | `allQuestsAllHeroes`, `totalCompletions`, `totalStreak` |
| `targetValue` | `Int64` | Target count |
| `weekOf` | `Date` | Challenge period |
| `isComplete` | `Bool` | Whether the challenge was achieved |
| `createdBy` | `String` | Guild Master who created it |

##### [NEW] [FamilyChallengeView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Guild/FamilyChallengeView.swift)

- **Parent side (Guild Dashboard)**: Clean admin card — title, target, progress bar, no game chrome. Simple form to create/edit challenges.
- **Hero side (Hero Dashboard)**: Full gamified presentation — "Boss fight" framing where the challenge is presented as a monster/obstacle the guild is fighting together. Shared progress bar with all heroes' pixel art avatars shown as a party. Mascot companion cheers them on.

---

#### 5.2 Guild Level & XP

##### [MODIFY] [Family.swift](file:///Users/kupan787/opencode/LootList/Project/Models/CloudKit/Family.swift)

- Add `guildXP: Int` and `guildLevel: Int` fields
- Guild earns XP from all members' quest completions (10% of hero XP spills into guild XP)
- Guild level unlocks: new theme options, guild banner customization, new challenge types

---

#### 5.3 Weekly MVP (Optional Leaderboard)

##### [NEW] [WeeklyMVPCardView.swift](file:///Users/kupan787/opencode/LootList/Project/Views/Guild/WeeklyMVPCardView.swift)

- Non-competitive framing: "This Week's MVP" highlights one hero
- Based on: most quests completed, longest streak, or most XP earned
- Shows hero's pixel art avatar with a crown/spotlight effect
- **Parent-toggleable** — can be disabled in guild settings for families where competition is unwanted

---

#### 5.4 Seasonal Events Framework

##### [NEW] [SeasonalEventService.swift](file:///Users/kupan787/opencode/LootList/Project/Services/SeasonalEventService.swift)

- Date-driven event system:
  - Halloween (Oct 15–Nov 1): spooky quest theming, skeleton avatar accessories, limited trophy
  - Winter (Dec 15–Jan 5): snowflake Gem bonus, winter equipment
  - Summer (Jun 1–Aug 31): extended daily challenge rewards
- Events modify: flavor text, color palette overrides, available shop items, bonus Gem multiplier
- Infrastructure only — specific events shipped as content updates

---

## CloudKit Schema Changes Summary

| Record Type | Action | Fields Added |
|---|---|---|
| `Profile` | MODIFY | `gems: Int64`, `streakShields: Int`, `equippedItems: [String]`, `mascotCompanion: String` |
| `Family` | MODIFY | `guildXP: Int64`, `guildLevel: Int` |
| `GemLedger` | NEW | Full record (see §2.1) |
| `OwnedEquipment` | NEW | Full record (see §3.3) |
| `FamilyChallenge` | NEW | Full record (see §5.1) |

## SwiftData Migration

- [MODIFY] [LootListSchema.swift](file:///Users/kupan787/opencode/LootList/Project/Models/Local/LootListSchema.swift)
  - Add `LootListSchemaV7` with new cache models
  - Migration from V6→V7: add `GemLedgerCache`, `OwnedEquipmentCache`, `FamilyChallengeCache`; add `gems`, `streakShields`, `equippedItems`, `mascotCompanion` to `ProfileCache`; add `guildXP`, `guildLevel` to `FamilyCache`

## Legacy Asset Cleanup

- [DELETE] `Project/Resources/AvatarPresets/` — all illustrated avatar assets removed
- [DELETE] `Project/Resources/AchievementIcons/` — replaced by pixel art trophy icons
- [MODIFY] `Project/Resources/Assets.xcassets/` — remove `avatar_knight_01` through `avatar_healer_04` image sets
- [MODIFY] [AvatarPreset](file:///Users/kupan787/opencode/LootList/Project/Services/AvatarService.swift) — `assetName` and `iconSystemName` properties redirect to pixel art sprite lookups instead of asset catalog references

---

## New Files Summary

| Phase | New Files | Modified Files | Deleted |
|---|---|---|---|
| **Phase 1** | 4 new files | 6 modified | — |
| **Phase 2** | 8 new files (incl. mascot) | 6 modified | — |
| **Phase 3** | 10 new files | 4 modified | Legacy avatar assets |
| **Phase 4** | 3 new files | 1 modified | — |
| **Phase 5** | 4 new files | 2 modified | — |
| **Total** | **~29 new files** | **~19 modified** | **Legacy art assets** |

---

## Verification Plan

### Automated Tests

Each phase adds corresponding tests:

```bash
# Run full test suite after each phase
xcodebuild test -project LootList.xcodeproj -scheme LootList -destination 'platform=iOS Simulator,name=iPhone 16'
```

- **XPService tests**: Verify streak multiplier calculations, level-up celebration triggering
- **GemService tests**: Verify idempotent crediting, balance calculation, spend validation
- **LootDropService tests**: Verify drop rate math, weighted random distribution, streak bonus cap
- **BonusObjectiveService tests**: Verify deterministic seed, objective evaluation, daily reset, no new task invention
- **SpriteCompositor tests**: Verify layer compositing produces expected pixel output
- **PixelSprite tests**: Verify palette indexing, transparent pixel handling

### Manual Verification

- **Visual QA** on device: XP bar animation smoothness, rarity border effects, pixel art rendering at all sizes, journey map scrolling performance
- **Sound QA**: All sound events play correctly, volume is appropriate, pitch randomization works, mute toggle respected
- **CloudKit sync**: New record types sync correctly between GM and Hero devices, Gem balance reconciles across devices
- **Schema migration**: V6→V7 migration runs cleanly on existing data, no data loss

---

## Resolved Design Decisions

| Decision | Resolution |
|---|---|
| **NPC Mascot** | ✅ Included in Phase 2. User-selectable companion (owl, dragon, fairy, fox, cat) that acts as a guide/cheerleader. Delivers daily bonus objectives (meta-goals about assigned quests, never new tasks). Contextual emotional state based on quest progress. |
| **Gem Pricing** | ✅ Start generous. Basic items: 💎 25. Mid-tier: 💎 100. Rare: 💎 250. Legendary: 💎 500. Fine-tune after playtesting. |
| **Legacy Avatar Art** | ✅ Fully replaced. Pixel art is the new default. Illustrated presets and asset catalog images removed. |
| **Journey Map** | ✅ Dashboard card on Hero Dashboard, expands to full-screen modal on tap. No 5th tab. |
| **Parent UI** | ✅ No gamification on the parent side. All pixel art, mascots, Gems, loot drops, celebrations, and sound design are Hero-only. Parents see clean admin UI. |
