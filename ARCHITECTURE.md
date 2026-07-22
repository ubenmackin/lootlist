# ARCHITECTURE.md — Loot List (Allowance Tracker)

## Project Soul

Loot List is a family chore and allowance tracker for iOS, themed as a fantasy RPG. Parents ("Guild Masters" / "Rangers") assign quests to their kids ("Heroes"), who complete them to earn gold (allowance). The app uses iCloud sync so the entire family sees the same data in real time.

**Why this architecture:**
- **CloudKit shared database** is the only viable native sync mechanism for a family app on Apple's ecosystem. It provides real-time push updates, offline support, and zero server cost.
- **SwiftUI + MVVM** is the modern Apple standard. Combined with iOS 26 SDK, we use the latest APIs and patterns.
- **Protocol-based service layer** allows us to swap implementations (e.g., manual ledger → FinanceKit) without touching views or models.
- **RPG theming is not cosmetic — it's core.** Every user-facing term, every screen, every notification uses the game vocabulary. This drives engagement for the kids.

---

## Tech Stack

- **Language:** Swift 6+
- **UI:** SwiftUI (iOS 26+)
- **Persistence:** CloudKit (shared database) + SwiftData (local cache)
- **Build:** XcodeGen (`project.yml`)
- **Architecture:** MVVM with Service layer abstraction
- **Min Target:** iOS 26.0
- **Sync:** CloudKit `CKShare` with per-user access control

---

## Architectural Decisions

### 1. CloudKit Shared Database (Family Sync)

The family is a CloudKit zone. The Guild Master creates the family and invites members via iCloud. All data lives in a shared `CKDatabase` zone.

- **Family creation:** First parent to sign in creates a `Family` record and becomes Guild Master
- **Kid onboarding:** Parent sends iCloud invite → kid accepts → kid's `Profile` is created with role `.hero`
- **Real-time sync:** CloudKit subscriptions push changes to all devices
- **Offline:** CloudKit queues changes locally and syncs when online

### 2. SpendingService Protocol (FinanceKit Abstraction)

```swift
protocol SpendingService {
    func fetchTransactions(for profile: Profile, in dateRange: DateInterval) async throws -> [LedgerEntry]
    func isAvailable() -> Bool
}
```

- **V1:** `ManualSpendingService` — user enters transactions manually
- **V2:** `FinanceKitSpendingService` — pulls from Apple Card via FinanceKit
- Views only interact with the protocol — swap implementations with zero UI changes

### 3. Quest Approval (Configurable Per Quest)

```swift
enum ApprovalMode: String, Codable {
    case autoApprove      // Kid marks done → done
    case parentVerify     // Kid marks done → pending → parent approves
}
```

- Set per `QuestTemplate` or per `Quest` assignment
- Default: `autoApprove`
- Parent notifications for pending verifications

### 4. RPG Terminology (User-Facing)

| Concept | User-Facing Term |
|---|---|
| Chores | Quests |
| Completed | Slain ⚔️ |
| Allowance | Gold |
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

### 5. Onboarding Flow

```
Opening Screen → "Welcome, Adventurer!"
  │
  ├─ "I'm a Parent" → Sign in with iCloud → Create Family → Guild Master
  │   └─ Invite Heroes via iCloud
  │
  └─ "I'm a Hero" → Sign in with iCloud → Enter Family Code → Select Avatar Class
      └─ Choose character preset → Ready to quest!
```

### 6. Notification System

Every notification type is individually toggleable per user:

| Event | Default (Hero) | Default (Parent) |
|---|---|---|
| Quest Assigned | ON | OFF |
| Quest Slain | OFF | ON |
| Quest Needs Review | OFF | ON |
| Quest Missed | ON | ON |
| Gold Earned (Loot Day) | ON | ON |
| Spending Logged | OFF | OFF |
| Trophy Earned | ON | ON |
| Streak Milestone | ON | ON |

---

## Project Structure

```
AllowanceTrax/
├── Project/
│   ├── App/
│   │   ├── LootListApp.swift              # App entry, CloudKit setup
│   │   └── AppState.swift                 # Global app state (auth, current user)
│   │
│   ├── Models/
│   │   ├── CloudKit/
│   │   │   ├── Family.swift               # Family record
│   │   │   ├── Profile.swift              # Character (parent/hero)
│   │   │   ├── QuestTemplate.swift        # Reusable quest blueprint
│   │   │   ├── Quest.swift                # Active quest assignment
│   │   │   ├── QuestCompletion.swift       # Completion record
│   │   │   ├── AllowancePeriod.swift      # Weekly payout cycle
│   │   │   ├── LedgerEntry.swift          # Spending chronicle
│   │   │   ├── Achievement.swift          # Trophy definition
│   │   │   ├── ProfileAchievement.swift   # Earned trophy
│   │   │   └── NotificationPreference.swift
│   │   │
│   │   ├── Enums/
│   │   │   ├── UserRole.swift             # GuildMaster, Ranger, Hero
│   │   │   ├── AvatarClass.swift          # Knight, Mage, Rogue, Guardian, Healer
│   │   │   ├── QuestSchedule.swift        # Daily, Weekly, SpecificDays
│   │   │   ├── ApprovalMode.swift         # AutoApprove, ParentVerify
│   │   │   ├── PayoutStatus.swift         # Active, PayoutPending, Paid
│   │   │   └── NotificationEventType.swift
│   │   │
│   │   └── ViewModels/
│   │       ├── HeroDashboardViewModel.swift
│   │       ├── QuestDetailViewModel.swift
│   │       ├── TreasuryViewModel.swift
│   │       ├── TrophyRoomViewModel.swift
│   │       ├── FamilyDashboardViewModel.swift
│   │       ├── QuestManagerViewModel.swift
│   │       ├── SettingsViewModel.swift
│   │       └── OnboardingViewModel.swift
│   │
│   ├── Services/
│   │   ├── CloudKitService.swift          # CRUD operations, subscriptions
│   │   ├── FamilyService.swift            # Family creation, invites, roles
│   │   ├── QuestService.swift             # Quest lifecycle, completion, approval
│   │   ├── TreasuryService.swift          # Gold tracking, payout calculations
│   │   ├── SpendingService.swift          # Protocol + manual implementation
│   │   ├── AchievementService.swift       # Trophy unlock logic
│   │   ├── NotificationService.swift      # Push notification management
│   │   ├── AvatarService.swift            # Character presets, appearance
│   │   └── XPService.swift                # XP calculation, leveling
│   │
│   ├── Views/
│   │   ├── Onboarding/
│   │   │   ├── WelcomeView.swift
│   │   │   ├── RoleSelectionView.swift
│   │   │   ├── FamilyCreationView.swift
│   │   │   ├── FamilyJoinView.swift
│   │   │   └── AvatarSelectionView.swift
│   │   │
│   │   ├── Hero/
│   │   │   ├── HeroDashboardView.swift    # Main tab: Quests
│   │   │   ├── QuestCardView.swift        # Individual quest display
│   │   │   ├── QuestDetailView.swift      # Quest info + mark complete
│   │   │   └── StreakBannerView.swift     # Streak counter display
│   │   │
│   │   ├── Treasury/
│   │   │   ├── TreasuryView.swift         # Main tab: Gold
│   │   │   ├── BalanceCardView.swift      # Current gold balance
│   │   │   ├── SpendingLogView.swift      # Scroll of Spending
│   │   │   └── LogSpendingView.swift      # Add spending entry
│   │   │
│   │   ├── Trophies/
│   │   │   ├── TrophyRoomView.swift       # Main tab: Hall of Heroes
│   │   │   ├── TrophyCardView.swift       # Individual trophy display
│   │   │   └── AvatarCardView.swift       # Character card with avatar
│   │   │
│   │   ├── Profile/
│   │   │   ├── ProfileView.swift          # Main tab: Character sheet
│   │   │   ├── CharacterSheetView.swift   # Stats, level, XP bar
│   │   │   └── NotificationSettingsView.swift
│   │   │
│   │   ├── Guild/
│   │   │   ├── FamilyDashboardView.swift  # Parent main: Family overview
│   │   │   ├── HeroStatusCard.swift       # Kid status summary
│   │   │   ├── QuestManagerView.swift     # Manage tab: All quests
│   │   │   ├── QuestAssignmentView.swift  # Assign/create quests
│   │   │   ├── TemplateManagerView.swift  # Manage templates
│   │   │   ├── PayoutHistoryView.swift    # Past payouts
│   │   │   └── GuildSettingsView.swift    # Settings tab
│   │   │
│   │   └── Shared/
│   │       ├── AvatarView.swift           # Rendered character
│   │       ├── ProgressBar.swift          # XP/progress bars
│   │       ├── GoldBadge.swift            # Gold amount display
│   │       ├── StreakBadge.swift          # Streak fire display
│   │       ├── TabBarView.swift           # Custom tab bar
│   │       └── NotificationToggleRow.swift
│   │
│   ├── Utilities/
│   │   ├── DateHelpers.swift              # Week calculations, payout dates
│   │   ├── CurrencyFormatter.swift        # Gold formatting
│   │   ├── CloudKitRecord.swift           # CKRecord encoding/decoding helpers
│   │   └── Haptics.swift                  # Haptic feedback
│   │
│   └── Resources/
│       ├── Assets.xcassets/               # Colors, icons
│       ├── AvatarPresets/                 # Character art (PNGs or SF Symbols)
│       └── AchievementIcons/              # Trophy icons
│
├── Project.yml                            # XcodeGen project spec
├── ARCHITECTURE.md                        # This file
└── .gitignore
```

---

## Data Model (CloudKit Records)

All records live in a shared CloudKit zone owned by the Family.

### Family
```
CKRecordType: "Family"
├── name: String                    # "The Pan Family"
├── createdBy: CKRecord.ID         # Owner (Guild Master)
├── createdAt: Date
└── inviteCode: String             # Short code for kids to join
```

### Profile (Character)
```
CKRecordType: "Profile"
├── displayName: String            # "Sir Cleanup"
├── avatarClass: String            # "knight", "mage", "rogue", "guardian", "healer"
├── avatarPresetID: String         # Which visual preset
├── role: String                   # "guildMaster", "ranger", "hero"
├── xp: Int                        # Total XP earned
├── level: Int                     # Computed from XP
├── iCloudUserID: CKRecord.ID     # Linked iCloud account
├── family: CKReference → Family
└── isActive: Bool
```

### QuestTemplate
```
CKRecordType: "QuestTemplate"
├── name: String                   # "Take Out Trash"
├── description: String            # "Bring bins to curb on collection day"
├── defaultGold: Double            # 1.00
├── xpReward: Int                  # 25
├── scheduleType: String           # "specificDays", "weeklyFlexible"
├── specificDays: [String]         # ["monday"] (weekday raw values)
├── approvalMode: String           # "autoApprove" or "parentVerify"
├── createdBy: CKReference → Profile
├── family: CKReference → Family
└── isActive: Bool
```

### Quest (Active Assignment)
```
CKRecordType: "Quest"
├── template: CKReference → QuestTemplate
├── assignee: CKReference → Profile
├── goldReward: Double             # Override from template if needed
├── xpReward: Int                  # Override from template if needed
├── scheduleType: String           # "specificDays", "weeklyFlexible", "allOrNothing"
├── allOrNothingGroup: String?     # Group ID for AON quests
├── approvalMode: String           # "autoApprove" or "parentVerify"
├── active: Bool
├── weekOf: Date                   # Starting Monday of this quest's week
├── createdBy: CKReference → Profile
└── family: CKReference → Family
```

### QuestCompletion (Completion Record)
```
CKRecordType: "QuestLog"
├── quest: CKReference → Quest
├── completedBy: CKReference → Profile
├── completedDate: Date
├── verificationStatus: String     # "autoApproved", "pending", "verified", "rejected"
├── verifiedBy: CKReference → Profile?  # Parent who verified
├── verifiedDate: Date?
├── weekOf: Date
└── family: CKReference → Family
```

### AllowancePeriod (Weekly Cycle)
```
CKRecordType: "AllowancePeriod"
├── weekOf: Date                   # Starting Monday
├── profile: CKReference → Profile
├── status: String                 # "active", "payoutPending", "paid"
├── totalEarned: Double            # Gold earned this week
├── questsCompleted: Int
├── questsTotal: Int
├── paidDate: Date?
├── paidAmount: Double?
└── family: CKReference → Family
```

### LedgerEntry (Spending Chronicle)
```
CKRecordType: "LedgerEntry"
├── profile: CKReference → Profile
├── amount: Double                 # Negative = spending
├── description: String            # "Coffee at Starbucks"
├── date: Date
├── source: String                 # "manual" or "financeKit" (V2)
└── family: CKReference → Family
```

### Achievement (Trophy Definition)
```
CKRecordType: "Achievement"
├── name: String                   # "First Steps"
├── description: String            # "Complete your first quest"
├── iconSystemName: String         # "star.fill"
├── category: String               # "quest", "streak", "gold", "special"
├── requirementType: String        # "firstQuest", "streak7", "gold100", etc.
├── requirementValue: Int          # Threshold value
└── family: CKReference → Family
```

### ProfileAchievement (Earned Trophy)
```
CKRecordType: "ProfileAchievement"
├── achievement: CKReference → Achievement
├── profile: CKReference → Profile
├── earnedDate: Date
└── family: CKReference → Family
```

### NotificationPreference
```
CKRecordType: "NotificationPreference"
├── profile: CKReference → Profile
├── eventType: String              # "questCompleted", "questAssigned", etc.
├── enabled: Bool                  # In-app toggle
├── pushEnabled: Bool              # Push notification toggle
└── family: CKReference → Family
```

---

## Achievement List (V1)

| Name | Description | Requirement |
|---|---|---|
| First Steps | Complete your first quest | 1 quest completion |
| Questing Squire | Complete 10 quests | 10 quest completions |
| Quest Knight | Complete 50 quests | 50 quest completions |
| Quest Legend | Complete 100 quests | 100 quest completions |
| Week Warrior | Complete all quests in a week | 100% weekly completion |
| Iron Will | 7-day streak | 7 consecutive days |
| Unstoppable | 30-day streak | 30 consecutive days |
| Gold Hoarder | Earn $100 lifetime | $100 total earned |
| Gold Magnate | Earn $500 lifetime | $500 total earned |
| Chronicler | Log 10 spending entries | 10 ledger entries |
| Wise Spender | Log spending for 4 weeks | 4 weeks of entries |
| Early Bird | Complete a quest before 9 AM | 1 quest before 9 AM |

---

## Sync & Conflict Resolution

- CloudKit handles conflict resolution automatically (last-write-wins for most fields)
- QuestCompletions are append-only (no conflicts possible)
- Profile XP/Level is computed from QuestCompletions (derived, not directly edited)
- Family settings changes are Guild Master only (role-gated in app logic)

---

## Key Patterns

### MVVM + Protocol Services
- Views observe ViewModels via `@Observable` (iOS 17+, preferred over `ObservableObject`)
- ViewModels depend on service protocols, not concrete implementations
- Services are injected via `@Environment` or initializer injection

### CloudKit Integration
- Use `CKContainer.default().sharedCloudDatabase` for family data
- `CKSubscription` for real-time push updates
- Local SwiftData cache for offline reads (synced from CloudKit)

### SwiftUI Best Practices (iOS 26)
- Use `@Observable` macro (not `ObservableObject` / `@Published`)
- Use `NavigationStack` (not `NavigationView`)
- Use `@State`, `@Binding`, `@Environment` for state management
- Use SF Symbols 6+ for icons
- Use `.containerRelativeFrame()` for adaptive layouts
- Use `.scrollTargetBehavior()` for scroll snapping
- Avoid deprecated: `UIApplication.shared.openURL`, `UIDevice.current`, etc.