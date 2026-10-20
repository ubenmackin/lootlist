//
//  LedgerStaleBanner.swift
//  LootList
//
//  Created by Ben Mackin on 10/20/26.
//

import SwiftUI

/// Shared stale banner for every grouped ledger surface.
/// WHY single source: stale family fallback plus sync snapshot were triplicated across ledger views; one view keeps scope resolution identical.
struct LedgerStaleBanner: View {
    @Environment(AppState.self) private var appState
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?

    private let familyRecordName: String?
    private let count: Int

    init(familyRecordName: String?, count: Int) {
        self.familyRecordName = familyRecordName
        self.count = count
    }

    private var targetFamily: String {
        familyRecordName ?? appState.family?.id.recordName ?? ""
    }

    /// WHY struct-only: banner renders this snapshot so the engine handle never enters the View.
    private var isSyncing: Bool {
        lifecycleCoordinator?.syncHealthSnapshot.isSyncing ?? false
    }

    var body: some View {
        if !targetFamily.isEmpty {
            StaleDataBanner(
                family: targetFamily,
                type: .ledgerEntry,
                count: count,
                isSyncing: isSyncing
            )
        }
    }
}
