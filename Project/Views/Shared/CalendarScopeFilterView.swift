//
//  CalendarScopeFilterView.swift
//  LootList
//
//  Created by Ben Mackin on 8/10/26.
//

import SwiftUI

/// Segmented control that switches a bound `CalendarScope` and optionally
/// renders a contextual date-range sublabel beneath it. Designed to embed in
/// both toolbar placements (sublabel hidden) and inline sticky/embedded view
/// headers (sublabel visible).
struct CalendarScopeFilterView: View {
    @Binding var scope: CalendarScope

    /// Toggles the contextual `dateRangeSublabel` row beneath the picker.
    var showsSublabel: Bool = true

    /// Payout day used to anchor the `.thisWeek` sublabel to the family's
    /// payout cycle. Defaults to `.sunday` (the `WeekMath` default) when the
    /// family context is unavailable.
    var payoutDay: PayoutDay = .sunday

    var body: some View {
        VStack(spacing: 4) {
            Picker("Calendar Scope", selection: $scope) {
                ForEach(CalendarScope.allCases) { option in
                    Text(option.displayLabel).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if showsSublabel, !scope.dateRangeSublabel(payoutDay: payoutDay).isEmpty {
                Text(scope.dateRangeSublabel(payoutDay: payoutDay))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
