//
//  ProcessPayoutButtonView.swift
//  LootList
//
//  Created by Ben Mackin on 9/01/26.
//

import SwiftUI

struct ProcessPayoutButtonView: View {
    let summary: WeekendSummary
    let isProcessingPayout: Bool
    let onConfirmPayout: () async -> Void

    @State private var showEarlyPayoutConfirm: Bool = false

    var body: some View {
        Button {
            showEarlyPayoutConfirm = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "banknote.fill")
                Text("Process Payout Now 🎁")
                    .font(.subheadline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.20)))
            .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
        }
        .buttonStyle(.plain)
        .disabled(isProcessingPayout)
        .accessibilityIdentifier("dashboard.processPayoutButton")
        .alert("Process Payout Now?", isPresented: $showEarlyPayoutConfirm) {
            Button("Confirm Payout", role: .destructive) {
                Task { await onConfirmPayout() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let amountStr = CurrencyFormatter.string(summary.pendingPayoutAmount)
            Text("Process payout of \(amountStr) across all heroes with completed quests? This will settle earnings for quests completed so far this week.")
        }
    }
}
