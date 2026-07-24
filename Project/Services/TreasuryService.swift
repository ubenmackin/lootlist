import CloudKit
import Foundation

@MainActor
@Observable
final class TreasuryService {
    private let cloudKit: CloudKitService
    let notificationService: NotificationService?

    init(cloudKit: CloudKitService, notificationService: NotificationService? = nil) {
        self.cloudKit = cloudKit
        self.notificationService = notificationService
    }

    func currentBalance(for profile: Profile) async throws -> Double {
        let earnings = try await goldFromQuests(profile: profile)
        let ledgerEntries = try await fetchAllLedgerEntries(profile: profile)
        let bonusGold = ledgerEntries
            .filter { $0.amount > 0 }
            .reduce(0.0) { $0 + $1.amount }
        let spending = ledgerEntries
            .filter { $0.amount < 0 }
            .reduce(0.0) { $0 + $1.amount }
        return earnings + bonusGold + spending
    }

    struct WeeklyBreakdown: Equatable, Sendable {
        var questsCount: Int = 0

        var goldFromQuests: Double = 0

        var bonusGold: Double = 0

        var totalEarned: Double = 0

        var spent: Double = 0

        var net: Double = 0
    }

    func weeklyBreakdown(profile: Profile,
                         weekOf: Date) async throws -> WeeklyBreakdown
    {
        let monday = TreasuryService.mondayOfWeek(for: weekOf)
        let weekRange = TreasuryService.weekRange(starting: monday)

        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: monday,
                                            weekEnding: weekRange.end)
        var goldFromQuests = try await sumGold(for: logs)
        let slainCount = logs.filter { TreasuryService.isSlain($0) }.count

        // Check if hero has strict All-or-Nothing payout policy enabled.
        if profile.payoutPolicy == .allOrNothing {
            let assigned = try await fetchAssignedQuests(profile: profile, weekOf: monday)
            if !assigned.isEmpty, slainCount < assigned.count {
                goldFromQuests = 0.0
            }
        }

        let ledgerEntries = try await fetchLedgerEntries(
            profile: profile, in: weekRange
        )
        let bonusGold = ledgerEntries
            .filter { $0.amount > 0 }
            .reduce(0.0) { $0 + $1.amount }
        let spent = ledgerEntries
            .filter { $0.amount < 0 }
            .reduce(0.0) { $0 + $1.amount }

        let totalEarned = goldFromQuests + bonusGold
        return WeeklyBreakdown(
            questsCount: slainCount,
            goldFromQuests: goldFromQuests,
            bonusGold: bonusGold,
            totalEarned: totalEarned,
            spent: spent,
            net: totalEarned + spent
        )
    }

    func getOrCreateAllowancePeriod(profile: Profile,
                                    weekOf: Date,
                                    family: Family) async throws -> AllowancePeriod
    {
        let monday = TreasuryService.mondayOfWeek(for: weekOf)
        let existing = try await fetchAllowancePeriod(profile: profile,
                                                      weekOf: monday)
        if let existing {
            return existing
        }

        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: monday,
                                            weekEnding: TreasuryService
                                                .weekRange(starting: monday).end)
        let slainCount = logs.filter { TreasuryService.isSlain($0) }.count

        let period = AllowancePeriod(
            weekOf: monday,
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            questsTotal: slainCount,
            family: CKRecord.Reference(recordID: family.id, action: .none)
        )
        return try await cloudKit.save(period)
    }

    func updateAllowance(period: AllowancePeriod,
                         totalEarned: Double? = nil,
                         questsCompleted: Int? = nil,
                         questsTotal: Int? = nil) async throws -> AllowancePeriod
    {
        var updated = period

        let profile = try await cloudKit.fetch(
            Profile.self, id: period.profile.recordID
        )

        let breakdown = try await weeklyBreakdown(profile: profile,
                                                  weekOf: period.weekOf)
        updated.totalEarned = totalEarned ?? breakdown.totalEarned
        updated.questsCompleted = questsCompleted ?? breakdown.questsCount
        if let questsTotal {
            updated.questsTotal = questsTotal
        }
        return try await cloudKit.save(updated)
    }

    func runPayout(period: AllowancePeriod) async throws {
        var updated = period
        updated.status = .paid
        updated.paidDate = Date()
        updated.paidAmount = updated.totalEarned
        _ = try await cloudKit.save(updated)

        if let notificationService {
            Task {
                if let profile = try? await cloudKit.fetch(Profile.self, id: period.profile.recordID),
                   let family = try? await cloudKit.fetch(Family.self, id: period.family.recordID)
                {
                    try? await notificationService.sendWeeklySummary(to: profile, family: family, weekOf: period.weekOf)
                }
            }
        }
    }

    private func goldFromQuests(profile: Profile) async throws -> Double {
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "completedBy == %@",
                                    profileRef as CVarArg)
        let logs = try await cloudKit.query(QuestCompletion.self,
                                            predicate: predicate)
        return try await sumGold(for: logs)
    }

    private func fetchAllLedgerEntries(profile: Profile) async throws -> [LedgerEntry] {
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@",
                                    profileRef as CVarArg)
        return try await cloudKit.query(LedgerEntry.self, predicate: predicate)
    }

    private func fetchLedgerEntries(profile: Profile,
                                    in dateRange: DateInterval) async throws -> [LedgerEntry]
    {
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "profile == %@ AND date >= %@ AND date <= %@",
            profileRef as CVarArg,
            dateRange.start as CVarArg,
            dateRange.end as CVarArg
        )
        return try await cloudKit.query(LedgerEntry.self, predicate: predicate)
    }

    private func fetchQuestLogs(profile: Profile,
                                weekStarting: Date,
                                weekEnding: Date) async throws -> [QuestCompletion]
    {
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "completedBy == %@ AND weekOf >= %@ AND weekOf <= %@",
            profileRef as CVarArg,
            weekStarting as CVarArg,
            weekEnding as CVarArg
        )
        return try await cloudKit.query(QuestCompletion.self, predicate: predicate)
    }

    private func fetchAssignedQuests(profile: Profile, weekOf: Date) async throws -> [Quest] {
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "assignee == %@ AND weekOf == %@",
            profileRef as CVarArg,
            weekOf as CVarArg
        )
        return try await cloudKit.query(Quest.self, predicate: predicate)
    }

    private func fetchAllowancePeriod(profile: Profile,
                                      weekOf: Date) async throws -> AllowancePeriod?
    {
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "profile == %@ AND weekOf == %@",
            profileRef as CVarArg,
            weekOf as CVarArg
        )
        let periods = try await cloudKit.query(AllowancePeriod.self,
                                               predicate: predicate)
        return periods.first
    }

    private func sumGold(for logs: [QuestCompletion]) async throws -> Double {
        var slainLogs: [QuestCompletion] = []
        slainLogs.reserveCapacity(logs.count)
        for log in logs where TreasuryService.isSlain(log) {
            slainLogs.append(log)
        }
        guard !slainLogs.isEmpty else { return 0 }

        let uniqueQuestIDs = Array(Set(slainLogs.map(\.quest.recordID)))
        var questCache: [CKRecord.ID: Quest] = [:]

        for chunk in uniqueQuestIDs.chunked(into: 100) {
            let predicate = NSPredicate(format: "recordID IN %@", chunk)
            do {
                let fetched: [Quest] = try await cloudKit.query(Quest.self, predicate: predicate)
                for quest in fetched {
                    questCache[quest.id] = quest
                }
            } catch {
                for questID in chunk {
                    if let fetched = try? await cloudKit.fetch(Quest.self, id: questID) {
                        questCache[questID] = fetched
                    }
                }
            }
        }

        var totalGold: Double = 0
        for log in slainLogs {
            if let quest = questCache[log.quest.recordID] {
                totalGold += quest.goldReward
            }
        }
        return totalGold
    }

    private static func isSlain(_ log: QuestCompletion) -> Bool {
        log.verificationStatus == .verified
            || log.verificationStatus == .autoApproved
    }

    static func weekRange(starting monday: Date) -> DateInterval {
        let cal = Calendar.iso8601UTC
        let start = cal.startOfDay(for: monday)

        let end = cal.date(byAdding: .second, value: AppConstants.Time.secondsInWeek - 1,
                           to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    static func mondayOfWeek(for date: Date) -> Date {
        let cal = Calendar.iso8601UTC
        let components = cal.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: date
        )
        return cal.date(from: components) ?? cal.startOfDay(for: date)
    }
}
