//
//  LedgerRevertMessage.swift
//  LootList
//
//  Created by Ben Mackin on 9/6/26.
//

import Foundation

/// Single source for ledger revert/save-failure toast copy.
/// WHY single source: the resolver and the delegate handler previously branched
/// on the same transfer/deposit/withdrawal sources inline; shared copy keeps them in sync.
enum LedgerRevertMessage {
    static func revertedMessage(for type: CachedRecordType, sourceRawValue: String?) -> String {
        switch type {
        case .ledgerEntry:
            ledgerRevertedMessage(sourceRawValue: sourceRawValue)
        case .goal:
            "Your goal update was reverted by newer server data. Pull to refresh."
        case .profile:
            "Your profile change was reverted by newer server data. Pull to refresh."
        default:
            "Your recent change was reverted — server data won. Pull to refresh."
        }
    }

    static func saveFailedMessage(for type: CachedRecordType?, sourceRawValue: String?) -> String {
        guard let type else {
            return "Your change couldn't be saved — pull to refresh."
        }
        switch type {
        case .ledgerEntry:
            return ledgerSaveFailedMessage(sourceRawValue: sourceRawValue)
        case .goal:
            return "Your goal change couldn't be saved — pull to refresh."
        case .profile:
            return "Your profile change couldn't be saved — pull to refresh."
        default:
            return "Your change couldn't be saved — pull to refresh."
        }
    }

    private static func ledgerRevertedMessage(sourceRawValue: String?) -> String {
        let source = sourceRawValue.flatMap(LedgerSource.init(rawValue:))
        switch source {
        case .transfer:
            return "Your transfer was reverted by newer server data. Pull to refresh."
        case .deposit:
            return "Your deposit was reverted by newer server data. Pull to refresh."
        case .withdrawal:
            return "Your withdrawal was reverted by newer server data. Pull to refresh."
        default:
            return "Your spending change was reverted by newer server data. Pull to refresh."
        }
    }

    private static func ledgerSaveFailedMessage(sourceRawValue: String?) -> String {
        let source = sourceRawValue.flatMap(LedgerSource.init(rawValue:))
        switch source {
        case .transfer:
            return "Your transfer couldn't be saved — pull to refresh."
        case .deposit:
            return "Your deposit couldn't be saved — pull to refresh."
        case .withdrawal:
            return "Your withdrawal couldn't be saved — pull to refresh."
        default:
            return "Your spending change couldn't be saved — pull to refresh."
        }
    }
}
