# Loot List

**Turn chores into quests. Turn allowance into adventure.**

Loot List is a family chore and allowance tracker that turns everyday responsibilities into an RPG-style adventure. Parents assign quests, kids complete them to earn real allowance money, and the whole family stays in sync through iCloud.

Built for iOS, designed for families.

---

## How It Works

### For Parents (Guild Masters)

- **Create your family guild** — set up your family, name your guild, and choose a weekly payout day.
- **Assign quests** — create reusable quest templates (chores, tasks, responsibilities) with reward amounts and XP.
- **Track completions** — review quest submissions from your kids, approve or reject them.
- **Manage the treasury** — see exactly how much the family owes, process weekly payouts, and log spending.
- **Invite your heroes** — share a simple link and your kids join their own guild from their device.

### For Kids (Heroes)

- **Check your quest board** — see your current quests, what's done, and what's pending.
- **Submit completions** — mark quests as finished and wait for your Guild Master to approve.
- **Track your earnings** — watch your allowance grow in real time.
- **Level up** — earn XP from quests, climb levels, and unlock trophies.
- **Pick your avatar** — choose from Warrior, Mage, Healer, Rogue, or Guardian character classes.

---

## Key Features

### 🗡️ Quest System

Quests are the heart of Loot List. Create custom quest templates with adjustable reward amounts, XP values, and rarity levels (Common, Rare, Epic, Legendary). Quests can be one-time or recurring on a weekly schedule, and parents can configure whether each quest auto-approves on completion or requires manual verification.

### 💰 Allowance & Treasury

Every quest has a real-money reward displayed in your local currency. Parents process weekly payouts for completed quests. Heroes can log personal spending entries in the "Scroll of Spending" — a running ledger of where their earned money goes. Three payout policies are available: standard per-quest payment, strict all-or-nothing weekly completion, or instant real-time settlement.

### 🏆 Achievements & Trophies

Twelve launch trophies track milestones across quest completions, streaks, earnings, and spending habits. Trophies include First Steps, Week Warrior, Iron Will (7-day streak), Fortune Hoarder (lifetime earnings milestones), and more. Earned trophies live in the Hall of Heroes.

### ⚡ Local-First & Offline Capable

Loot List is built with a local-first architecture using a SwiftData cache and Apple's native background `CKSyncEngine`.
- **Instant Local Writes & Offline Queuing:** Primary actions — completing a quest, approving a chore, creating a template, logging spending — save immediately to your device's local SwiftData cache with zero UI lag. Pending updates are queued offline and synchronized via `CKSyncEngine` when connectivity resumes.
- **Idempotent Rewards & Settlement:** Cross-device operations use deterministic record naming (`reward-<completionID>`, `payout-<periodID>`) and monotonic merges to guard against duplicate XP minting and concurrent payout races.
- **Offline Usability:** Kids can mark quests complete on the go or without Wi-Fi; pending updates sync automatically once back online.

### 👨‍👩‍👧‍👦 Family Sync via iCloud

All family data syncs securely through your private Apple iCloud container. The Guild Master sets up the family guild and invites family members via Apple Messages or private iCloud sharing. Every device stays in sync — quest updates, allowances, spending logs, and trophies flow across all devices in real time.

### 🔐 Privacy-First, No External Accounts

Loot List does not collect personal information, does not track you, and does not host your data on third-party servers. Everything stays securely inside your family's iCloud storage. No passwords to remember, no third-party account creation, and no ads.

---

## RPG Terminology Cheat Sheet

The app wraps everyday family tasks in an RPG theme. Here's a quick reference:

| In Loot List | It Actually Means |
|---|---|
| Quest | Chore or task |
| Hero | Your child |
| Guild Master | Parent (owner) |
| Ranger | Parent (admin) |
| Guild | Family |
| Scroll of Spending | Spending log |
| XP / Level Up | Experience points |
| Trophy / Hall of Heroes | Achievements |
| Sunday Loot Day | Weekly allowance payout |
| Combo Streak 🔥 | Consecutive-day streak |
| Loot Drop 🎁 | Bonus reward |

---

## Getting Started

1. Download **Loot List** from the App Store on your iOS device.
2. Sign in with your Apple ID (iCloud is required for family sync).
3. Choose your role — Parent or Hero — and follow the onboarding prompts.
4. If you're a parent, create your family guild and assign your first quests.
5. Share your guild invitation with your kids so they can join.

---

## Platform Requirements

- **iOS 26.0 or later** (iPhone & iPad)
- iCloud account enabled for family sync

---

## Support & Contact

Loot List is free and open source. Report issues, request features, or open a discussion on GitHub:

**[ubenmackin/lootlist](https://github.com/ubenmackin/lootlist)**

For privacy questions, see our [Privacy Policy](PRIVACY_POLICY.md).
