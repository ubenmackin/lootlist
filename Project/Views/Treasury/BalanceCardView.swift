//
//  BalanceCardView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

enum GoldFormat {
    static func magnitude(_ amount: Double) -> String {
        CurrencyFormatter.magnitude(amount)
    }

    static func signed(_ amount: Double) -> String {
        let body = magnitude(amount)
        if amount < 0 {
            return "−\(body)"
        }
        if amount > 0 {
            return "+\(body)"
        }
        return body
    }
}

struct BalanceCardView: View {
    let balance: Double?

    let weekOf: Date?

    let status: PayoutStatus?

    var body: some View {
        VStack(spacing: 16) {
            Text(amountText)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(balance == nil ? .secondary : .primary)
                .contentTransition(.numericText())

            Text("Money")
                .font(.headline)
                .foregroundStyle(.secondary)

            if let weekOf {
                Text(weekLabel(for: weekOf))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let status {
                statusPill(for: status)
                    .padding(.top, 8)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        )
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current balance \(balance.map { GoldFormat.magnitude($0) } ?? "loading")")
    }

    private var amountText: String {
        guard let balance else { return "—" }
        return GoldFormat.magnitude(balance)
    }

    private func weekLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let monday = TreasuryService.mondayOfWeek(for: date)
        return "Week of \(formatter.string(from: monday))"
    }

    private func statusPill(for status: PayoutStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.iconSystemName)
            Text(status.displayName)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(.thinMaterial)
        )
    }
}
