//
//  FamilyDashboardView+Sections.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import SwiftUI

// Supporting models shared by FamilyDashboardView and ChildHubCardsView.
// WHY: isolated file contains only value types with no mutable view state;
// all view helpers were consolidated into FamilyDashboardView.swift to restore
// file-scope isolation and Swift 6 data-race safety. This file no longer
// hosts an extension that reaches into FamilyDashboardView's @State/@Environment.
// WHY: single shared weekly-amount point for dashboard/hub sparklines and payout charts;
// String id is the UTC dayKey for bucketed points, recordName for per-period points.
struct WeeklyEarningPoint: Identifiable {
    let id: String
    let weekStart: Date
    let label: String
    let amount: Double
    let isPaid: Bool

    init(id: String, weekStart: Date, label: String, amount: Double, isPaid: Bool = false) {
        self.id = id
        self.weekStart = weekStart
        self.label = label
        self.amount = amount
        self.isPaid = isPaid
    }
}

struct ChildCardHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
