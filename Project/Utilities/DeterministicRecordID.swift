//
//  DeterministicRecordID.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import CryptoKit
import Foundation

/// Single-source factories for deterministic CloudKit record names used across
/// all money-movement flows. Centralizing prefixes and formatting prevents
/// cross-device dedupe divergence.
enum DeterministicRecordID {
    /// Single-source root for all goal-contribution record names.
    /// All prefix checks and ID factories must route through this constant.
    private static let contribRoot = "contrib-"

    /// Single-source root for goal-purchase debit records.
    private static let purchaseRoot = "purchase-"

    /// Prefix for a specific goal's contribution records: `contrib-{goalRecordName}-`.
    static func contributionPrefix(for goalRecordName: String) -> String {
        "\(contribRoot)\(goalRecordName)-"
    }

    /// Returns true when `recordName` is any contribution record.
    static func isContributionRecord(_ recordName: String) -> Bool {
        recordName.hasPrefix(contribRoot)
    }

    /// WHY scoped check: prefix alone collides across goals, so goal binding confirms ownership.
    static func isContribution(_ recordName: String, for goalRecordName: String) -> Bool {
        recordName.hasPrefix(contributionPrefix(for: goalRecordName))
    }

    /// WHY single source: purchase debit identity stays behind the factory so dedupe never drifts.
    static func isPurchaseRecord(_ recordName: String, goalRecordName: String) -> Bool {
        recordName == purchase(goalRecordName: goalRecordName)
    }

    static func isPurchaseRecord(_ recordName: String) -> Bool {
        recordName.hasPrefix(purchaseRoot)
    }

    static func interest(profileRecordName: String, monthKey: String) -> String {
        "interest-\(profileRecordName)-\(monthKey)"
    }

    static func match(goalRecordName: String, contributionEventID: String) -> String {
        "match-\(goalRecordName)-\(contributionEventID)"
    }

    static func contribution(goalRecordName: String, sourceEventID: String) -> String {
        "\(contributionPrefix(for: goalRecordName))\(sourceEventID)"
    }

    /// WHY single source: reward minting dedupes on this name across devices.
    static func reward(completionID: String) -> String {
        "reward-\(completionID)"
    }

    /// WHY UTC: same instant resolves to same month on every device for dedupe.
    static func monthKeyUTC(for date: Date, calendar: Calendar = .iso8601UTC) -> String {
        WeekMath.monthKey(for: date, calendar: calendar)
    }

    /// Deterministic purchase debit for a goal: `purchase-{goalRecordName}`.
    static func purchase(goalRecordName: String) -> String {
        "\(purchaseRoot)\(goalRecordName)"
    }

    static func transfer(profileRecordName: String, transferID: String) -> String {
        "transfer-\(profileRecordName)-\(transferID)"
    }

    static func `import`(hex: String) -> String {
        "import-\(hex)"
    }

    static func payout(periodRecordName: String) -> String {
        "payout-\(periodRecordName)"
    }

    /// WHY single source: concurrent period creates dedupe on this name across devices.
    static func allowancePeriod(familyRecordName: String, profileRecordName: String, weekStart: Date) -> String {
        "period-\(familyRecordName)-\(profileRecordName)-\(Int(weekStart.timeIntervalSince1970))"
    }

    static func realtimePayout(periodRecordName: String) -> String {
        "rt-\(periodRecordName)"
    }

    /// WHY single source: CloudKit/cache round-trips quantize dates so exact equality forks deterministic names.
    static func isSameMillisecond(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 0.001
    }

    // MARK: - Collision Extension (single source)

    /// Byte count for collision hex; renders as `c` plus 8 hex chars via `hexPrefix`.
    static let collisionHexByteCount = 4

    /// WHY single source: waterfall Short legs append this marker, so every strip path shares one constant.
    private static let shortcoverSuffix = "-shortcover"

    /// WHY single source: grouping plus delete convergence share one shortcover check so forks never drift.
    static func isShortcoverName(_ recordName: String) -> Bool {
        recordName.hasSuffix(shortcoverSuffix) || recordName.contains("\(shortcoverSuffix)-")
    }

    /// WHY single source: Spend legs carry the base while Short legs append `-shortcover` with forks on either side, so peel then strip to converge.
    static func waterfallBase(_ recordName: String) -> String {
        var core = recordName
        if core.hasSuffix(shortcoverSuffix) {
            core = String(core.dropLast(shortcoverSuffix.count))
        } else if let range = core.range(of: "\(shortcoverSuffix)-") {
            core = String(core[..<range.lowerBound])
        }
        return stripCollisionExtension(core)
    }

    /// WHY c-prefix: leading c disambiguates forks from numeric tails so every mint strips while legit bases never do.
    static func collisionExtendedName(base: String, payload: String, date: Date) -> String {
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        let hash = SHA256.hash(data: Data(payload.utf8))
        let raw = hash.hexPrefix(collisionHexByteCount)
        let hex = "c\(raw)"
        let msSuffix = ms % 1000
        return "\(base)-\(hex)-\(msSuffix)"
    }

    /// WHY both layers: ledger forks carry base-hex-msSuffix while legacy drawdown forks carry base-hex alone, so strip either iteratively.
    static func stripCollisionExtension(_ recordName: String) -> String {
        // WHY shortcover tail: waterfall Short legs append -shortcover after collision forks, so peel before stripping then re-apply to converge with Spend legs.
        var tail = ""
        var working = recordName
        if working.hasSuffix(shortcoverSuffix), working.count > shortcoverSuffix.count {
            tail = shortcoverSuffix
            working = String(working.dropLast(shortcoverSuffix.count))
        }
        var current = working
        while true {
            let next = stripOneCollisionLayer(current)
            if next == current {
                return current + tail
            }
            current = next
        }
    }

    /// WHY two-layer first: the convergent fork peels before the legacy single layer so nested drawdown markers link.
    private static func stripOneCollisionLayer(_ recordName: String) -> String {
        let parts = recordName.split(separator: "-")
        guard parts.count >= 2 else { return recordName }
        if parts.count >= 3,
           let last = parts.last,
           (1 ... 3).contains(last.count),
           last.allSatisfy(\.isNumber),
           isCollisionHex(String(parts[parts.count - 2]))
        {
            return parts.dropLast(2).joined(separator: "-")
        }
        if let last = parts.last, isCollisionHex(String(last)) {
            return parts.dropLast().joined(separator: "-")
        }
        return recordName
    }

    /// WHY c-prefix plus legacy: new forks carry leading c so all-digit suffixes still strip; legacy letter-gated forks still strip while numeric tails never do.
    static func isCollisionHex(_ value: String) -> Bool {
        if value.count == 9 {
            let lower = value.lowercased()
            guard lower.hasPrefix("c") else { return false }
            return String(lower.dropFirst()).allSatisfy(\.isHexDigit)
        }
        guard value.count == 8, value.allSatisfy(\.isHexDigit) else { return false }
        return value.contains(where: \.isLetter)
    }
}

/// Canonical deterministic identity helpers that must remain single-source.
///
/// `monthKeyUTC` / `dayKeyUTC` are intentionally thin — the authoritative
/// calendar math lives in `WeekMath` so timezone handling cannot diverge
/// between interest/match/daily-login flows.
enum DeterministicIdentity {
    /// UTC `yyyy-MM-dd` day key for daily-login deterministic dedupe.
    /// Thin wrapper over `WeekMath.dayKey(for:calendar:)` so daily-login shares
    /// the single-source `Calendar.iso8601UTC` path with `WeekMath` and monthKey.
    static func dayKeyUTC(for date: Date, calendar: Calendar = .iso8601UTC) -> String {
        WeekMath.dayKey(for: date, calendar: calendar)
    }
}

/// Check-before-apply idempotency guard for deterministic record names.
///
/// Every money-movement write mints a deterministic record name so
/// `CKSyncEngine` dedupes across devices. The guard is the second layer:
/// inspecting the local cache before enqueue prevents double-run creation
/// even before CloudKit reconciliation.
enum IdempotencyGuard {
    /// Returns true when `recordName` already exists in the cached ledger slice.
    static func containsDeterministicID(_ recordName: String, in entries: [LedgerEntryCache]) -> Bool {
        entries.contains(where: { $0.recordName == recordName })
    }

    /// WHY domain mirror: pre-cache flows check the same identity without a store read.
    static func containsDeterministicID(_ recordName: String, in entries: [LedgerEntry]) -> Bool {
        entries.contains(where: { $0.id.recordName == recordName })
    }
}
