//
//  SchemaSeedService.swift
//  LootList
//
//  Created by Ben Mackin on 9/07/26.
//

#if DEBUG
    import CloudKit
    import Foundation
    import os

    /// DEBUG-only CloudKit Dev schema registration. Saves one filled exemplar per
    /// record type into the active family zone, then deletes the rows.
    /// WHY ephemeral direct write: seed rows must never enter SwiftData balances or the roster,
    /// so this never touches CacheService, never enqueues uploads, and never calls ingest().
    /// Scope stays narrow: reserved schemaseed- names, active-family zone only, best-effort
    /// cleanup on every path. Family itself is the pre-existing parent, never seeded.
    @MainActor
    final class SchemaSeedService {
        private static let logger = Logger(category: "SchemaSeed")
        private static let seedPrefix = "schemaseed"

        struct SeedReport: Sendable {
            let recordType: String
            let recordName: String
        }

        private struct SeedProgress {
            var savedIDs: [CKRecord.ID] = []
            var report: [SeedReport] = []
        }

        private let cloudKit: any CloudKitServiceProtocol

        init(cloudKit: any CloudKitServiceProtocol) {
            self.cloudKit = cloudKit
        }

        func pushSchemaSeed(family: Family) async throws -> [SeedReport] {
            let zoneID = family.id.zoneID
            let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
            let profile = makeSeedProfile(familyRef: familyRef, zoneID: zoneID)
            let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
            let template = makeSeedTemplate(profileRef: profileRef, familyRef: familyRef, zoneID: zoneID)
            let quest = makeSeedQuest(template: template, profile: profile, profileRef: profileRef, familyRef: familyRef, zoneID: zoneID)
            let completion = makeSeedCompletion(quest: quest, profileRef: profileRef, familyRef: familyRef, zoneID: zoneID)
            let achievement = makeSeedAchievement(familyRef: familyRef, zoneID: zoneID)

            var progress = SeedProgress()
            do {
                try await saveSeed(profile, zoneID: zoneID, progress: &progress)
                try await saveSeed(template, zoneID: zoneID, progress: &progress)
                try await saveSeed(quest, zoneID: zoneID, progress: &progress)
                try await saveSeed(completion, zoneID: zoneID, progress: &progress)
                try await saveSeed(makeSeedPeriod(profileRef: profileRef, familyRef: familyRef, zoneID: zoneID), zoneID: zoneID, progress: &progress)
                try await saveSeed(makeSeedLedger(profileRef: profileRef, familyRef: familyRef, zoneID: zoneID), zoneID: zoneID, progress: &progress)
                try await saveSeed(makeSeedGoal(profileRef: profileRef, familyRef: familyRef, zoneID: zoneID), zoneID: zoneID, progress: &progress)
                try await saveSeed(achievement, zoneID: zoneID, progress: &progress)
                try await saveSeed(
                    makeSeedProfileAchievement(achievement: achievement, profileRef: profileRef, familyRef: familyRef, zoneID: zoneID),
                    zoneID: zoneID,
                    progress: &progress
                )
                try await saveSeed(makeSeedPreference(profileRef: profileRef, familyRef: familyRef, zoneID: zoneID), zoneID: zoneID, progress: &progress)
                try await saveSeed(makeSeedGemLedger(profile: profile, familyRef: familyRef, zoneID: zoneID), zoneID: zoneID, progress: &progress)
                try await saveSeed(makeSeedReward(profileRef: profileRef, completion: completion, familyRef: familyRef, zoneID: zoneID), zoneID: zoneID, progress: &progress)
            } catch {
                Self.logger.error("Schema seed save failed: \(error, privacy: .private)")
                await deleteBestEffort(progress.savedIDs, zoneID: zoneID)
                throw error
            }
            // WHY keep-the-schema: deleting rows leaves Dev field definitions in place, so the family stays clean.
            // WHY best-effort: one delete failure must not orphan remaining seed rows, so attempt all and report each failure.
            await deleteBestEffort(progress.savedIDs, zoneID: zoneID)
            return progress.report
        }

        private func saveSeed<T: CloudKitRecord>(_ model: T, zoneID: CKRecordZone.ID, progress: inout SeedProgress) async throws where T.ID == CKRecord.ID {
            // WHY prefix gate: only reserved seed names may reach the server, so a caller mistake fails closed instead of overwriting production rows.
            guard model.id.recordName.hasPrefix("\(Self.seedPrefix)-") else {
                throw CloudKitServiceError.invalidArguments("Schema seed must use reserved prefix")
            }
            guard model.id.zoneID == zoneID else {
                throw CloudKitServiceError.invalidArguments("Schema seed must stay in the active family zone")
            }
            let saved = try await cloudKit.save(model, in: zoneID, using: nil)
            progress.savedIDs.append(saved.id)
            progress.report.append(SeedReport(recordType: T.recordType, recordName: saved.id.recordName))
        }

        private func deleteBestEffort(_ ids: [CKRecord.ID], zoneID: CKRecordZone.ID) async {
            for recordID in ids {
                // WHY double gate: cleanup must never delete production rows, so skip anything outside the seed namespace or zone.
                guard recordID.recordName.hasPrefix("\(Self.seedPrefix)-"), recordID.zoneID == zoneID else { continue }
                do {
                    try await cloudKit.delete(recordID, in: zoneID, using: nil)
                } catch {
                    Self.logger.warning("Schema seed cleanup delete failed: \(error, privacy: .private)")
                }
            }
        }

        private static func seedID(_ name: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
            CKRecord.ID(recordName: "\(seedPrefix)-\(name)", zoneID: zoneID)
        }

        private func makeSeedProfile(familyRef: CKRecord.Reference, zoneID: CKRecordZone.ID) -> Profile {
            var seedProfile = Profile(
                displayName: "Schema Seed",
                avatarClass: .mage,
                avatarPresetID: "seed-preset",
                customAvatarImageData: Data([0x89, 0x50, 0x4E, 0x47]),
                role: .hero,
                iCloudUserID: CKRecord.ID(recordName: "\(Self.seedPrefix)-user"),
                family: familyRef,
                payoutPolicy: .perQuest,
                payoutDay: .sunday,
                gems: 5,
                streakShields: 1,
                mascotCompanion: "fox",
                ownedEquipment: ["seed-sword"],
                equippedItems: ["seed-sword"],
                dailyLoginLastClaimDay: "2026-01-01",
                dailyLoginCycleDay: 2,
                dailyLoginStreakDays: 3,
                claimedBonusObjectives: ["seed-objective"],
                journeyMapLastSeenLevel: 2,
                avatarEmoji: "🦊",
                splitPercentSpend: 50,
                splitPercentShort: 30,
                splitPercentLong: 20,
                interestEnabled: true,
                interestBucket: BucketKind.shortTermSave.rawValue,
                interestRateBps: 250,
                interestIsCompound: true,
                matchEnabled: true,
                matchRateBps: 5000,
                matchMonthlyCapPennies: 1000,
                id: Self.seedID("profile", zoneID: zoneID)
            )
            seedProfile.xp = 120
            seedProfile.level = 3
            return seedProfile
        }

        private func makeSeedTemplate(profileRef: CKRecord.Reference, familyRef: CKRecord.Reference, zoneID: CKRecordZone.ID) -> QuestTemplate {
            QuestTemplate(
                name: "Schema Seed Template",
                description: "Schema seed",
                defaultGold: 500,
                xpReward: 50,
                scheduleType: .specificDays,
                specificDays: ["monday", "wednesday"],
                targetCount: 2,
                isAllOrNothing: true,
                approvalMode: .parentVerify,
                createdBy: profileRef,
                family: familyRef,
                isActive: true,
                id: Self.seedID("questtemplate", zoneID: zoneID)
            )
        }

        private func makeSeedQuest(template: QuestTemplate, profile: Profile, profileRef: CKRecord.Reference, familyRef: CKRecord.Reference, zoneID: CKRecordZone.ID) -> Quest {
            Quest(
                template: CKRecord.Reference(recordID: template.id, action: .none),
                assignee: profileRef,
                goldReward: 1000,
                xpReward: 100,
                scheduleType: .specificDays,
                targetCount: 2,
                approvalMode: .parentVerify,
                weekOf: Date(),
                createdBy: profileRef,
                family: familyRef,
                name: "Schema Seed Quest",
                descriptionText: "Schema seed",
                xpBanked: 10,
                claimedByProfileRecordName: profile.id.recordName,
                claimedAt: Date(),
                id: Self.seedID("quest", zoneID: zoneID)
            )
        }

        private func makeSeedCompletion(quest: Quest, profileRef: CKRecord.Reference, familyRef: CKRecord.Reference, zoneID: CKRecordZone.ID) -> QuestCompletion {
            var completion = QuestCompletion(
                quest: CKRecord.Reference(recordID: quest.id, action: .none),
                completedBy: profileRef,
                approvalMode: .parentVerify,
                weekOf: Date(),
                family: familyRef,
                xpCredited: 50,
                id: Self.seedID("questlog", zoneID: zoneID)
            )
            completion.verificationStatus = .verified
            completion.verifiedBy = profileRef
            completion.verifiedDate = Date()
            return completion
        }

        private func makeSeedPeriod(profileRef: CKRecord.Reference, familyRef: CKRecord.Reference, zoneID: CKRecordZone.ID) -> AllowancePeriod {
            AllowancePeriod(
                weekOf: Date(),
                profile: profileRef,
                status: .paid,
                totalEarned: 2500,
                questsCompleted: 3,
                questsTotal: 5,
                paidDate: Date(),
                paidAmount: 2500,
                family: familyRef,
                id: Self.seedID("allowanceperiod", zoneID: zoneID)
            )
        }

        private func makeSeedLedger(profileRef: CKRecord.Reference, familyRef: CKRecord.Reference, zoneID: CKRecordZone.ID) -> LedgerEntry {
            LedgerEntry(
                profile: profileRef,
                amount: 400,
                description: "Schema seed transfer",
                location: "Schema seed",
                source: LedgerSource.transfer.rawValue,
                bucketKind: BucketKind.shortTermSave.rawValue,
                fromBucket: BucketKind.spend.rawValue,
                toBucket: BucketKind.shortTermSave.rawValue,
                family: familyRef,
                id: Self.seedID("ledger-transfer", zoneID: zoneID)
            )
        }

        private func makeSeedGoal(profileRef: CKRecord.Reference, familyRef: CKRecord.Reference, zoneID: CKRecordZone.ID) -> Goal {
            Goal(
                profile: profileRef,
                family: familyRef,
                bucketKind: .shortTermSave,
                name: "Schema Seed Goal",
                category: "Schema seed",
                emojiIcon: "🎯",
                targetAmountPennies: 5000,
                completedAt: Date(),
                isArchived: true,
                targetDate: Date(),
                linkURL: "https://example.com/seed",
                imageURL: "https://example.com/seed.jpg",
                id: Self.seedID("goal", zoneID: zoneID)
            )
        }

        private func makeSeedAchievement(familyRef: CKRecord.Reference, zoneID: CKRecordZone.ID) -> Achievement {
            Achievement(
                name: "Schema Seed",
                description: "Schema seed",
                iconSystemName: "star.fill",
                category: .quest,
                requirementType: .firstQuest,
                requirementValue: 1,
                family: familyRef,
                id: Self.seedID("achievement", zoneID: zoneID)
            )
        }

        private func makeSeedProfileAchievement(achievement: Achievement, profileRef: CKRecord.Reference, familyRef: CKRecord.Reference,
                                                zoneID: CKRecordZone.ID) -> ProfileAchievement
        {
            ProfileAchievement(
                achievement: CKRecord.Reference(recordID: achievement.id, action: .none),
                profile: profileRef,
                family: familyRef,
                id: Self.seedID("profileachievement", zoneID: zoneID)
            )
        }

        private func makeSeedPreference(profileRef: CKRecord.Reference, familyRef: CKRecord.Reference, zoneID: CKRecordZone.ID) -> NotificationPreference {
            NotificationPreference(
                profile: profileRef,
                eventType: .questAssigned,
                enabled: true,
                family: familyRef,
                id: Self.seedID("notificationpreference", zoneID: zoneID)
            )
        }

        private func makeSeedGemLedger(profile: Profile, familyRef: CKRecord.Reference, zoneID: CKRecordZone.ID) -> GemLedger {
            GemLedger(
                profileRecordName: profile.id.recordName,
                family: familyRef,
                amount: 10,
                source: "quest",
                sourceDetail: "schema seed",
                createdAt: Date(),
                id: Self.seedID("gemledger", zoneID: zoneID)
            )
        }

        private func makeSeedReward(profileRef: CKRecord.Reference, completion: QuestCompletion, familyRef: CKRecord.Reference, zoneID: CKRecordZone.ID) -> RewardEvent {
            RewardEvent(
                profile: profileRef,
                questCompletion: CKRecord.Reference(recordID: completion.id, action: .none),
                xpAmount: 50,
                goldAmount: 1000,
                family: familyRef,
                id: Self.seedID("rewardevent", zoneID: zoneID)
            )
        }
    }
#endif
