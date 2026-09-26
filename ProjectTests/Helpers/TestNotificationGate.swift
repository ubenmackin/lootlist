//
//  TestNotificationGate.swift
//  LootList
//
//  Created by Ben Mackin on 9/26/26.
//

import CloudKit
import Foundation

/// WHY single gate: notification-center calls hang with no iCloud account, so suites share one timeout.
@MainActor
enum TestNotificationGate {
    static func iCloudAccountAvailable() async -> Bool {
        let status: CKAccountStatus? = await withTaskGroup(of: CKAccountStatus?.self) { group in
            group.addTask { await (try? CKContainer.default().accountStatus()) ?? .couldNotDetermine }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return status == .available
    }
}
