//
//  LedgerDateRangeMenu.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import SwiftUI

/// Toolbar menu that switches a ledger between "This Week" and "All Time".
struct LedgerDateRangeMenu: View {
    @Binding var showAllTime: Bool

    private enum Scope: String, CaseIterable, Identifiable {
        case thisWeek = "This Week"
        case allTime = "All Time"

        var id: String {
            rawValue
        }
    }

    var body: some View {
        CheckmarkMenu(
            systemImage: "calendar",
            options: Scope.allCases,
            selected: showAllTime ? Scope.allTime : .thisWeek,
            onSelect: { showAllTime = $0 == .allTime },
            title: { $0.rawValue }
        )
    }
}
