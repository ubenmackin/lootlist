//
//  NotificationPrimeCard.swift
//  LootList
//
//  Created by Ben Mackin on 9/5/26.
//

import SwiftUI

/// Shared notification-prime explainer used by `NotificationPrimeView` and `HeroHomeView.checklistNotificationSheet`.
/// Extracted to eliminate 70% text duplication across onboarding and checklist surfaces.
struct NotificationPrimeCard: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Stay in the loop?")
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                bulletRow("Know when a quest needs your review")
                bulletRow("Get allowance day updates")
                bulletRow("Nudge for streaks")
            }
            .frame(maxWidth: 360)
            .padding(16)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
        }
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.body.weight(.bold))
                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
