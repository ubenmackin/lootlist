//
//  PayoutChartHeaderView.swift
//  LootList
//
//  Created by Ben Mackin on 9/01/26.
//

import Charts
import SwiftUI

struct PayoutChartHeader: View {
    let data: [WeeklyEarningPoint]

    var body: some View {
        if data.isEmpty {
            ghostChart
        } else {
            Chart {
                ForEach(data) { datum in
                    BarMark(
                        x: .value("Week", datum.weekStart, unit: .weekOfYear),
                        y: .value("Earned", datum.amount)
                    )
                    .foregroundStyle(datum.isPaid ? Color(DesignSystemConstants.Colors.primaryGreen) : Color(DesignSystemConstants.Colors.pendingAmber))
                    .cornerRadius(4)
                }
            }
            .frame(height: 100)
            .clipped()
        }
    }

    private var ghostChart: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0 ..< 12, id: \.self) { idx in
                let heights: [CGFloat] = [20, 35, 15, 40, 25, 30, 18, 45, 22, 28, 32, 16]
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: heights[idx % heights.count])
            }
        }
        .frame(height: 100)
        .clipped()
        .opacity(0.7)
        .accessibilityHidden(true)
    }
}
