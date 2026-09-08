//
//  HeroHomeChecklistSheetsView.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import SwiftUI

/// Checklist sheet content extracted from HeroHomeView so the home stays a
/// thin orchestrator; actions ride closures back to the parent.
struct HeroHomeNotificationPrimeSheetView: View {
    let onEnable: () -> Void
    let onSkip: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                NotificationPrimeCard()
                    .padding(.top, 32)
                    .padding(.horizontal, 24)

                Button {
                    onEnable()
                } label: {
                    Text("Turn On")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(DesignSystemConstants.Colors.accentBlue))
                .padding(.horizontal, 24)
                .accessibilityIdentifier("heroChecklist.enableNotificationsButton")

                Button {
                    onSkip()
                } label: {
                    Text("Maybe Later")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("heroChecklist.skipNotificationsButton")

                Spacer(minLength: 0)
            }
            .padding(.vertical, 16)
            .navigationTitle("Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                }
            }
        }
    }
}

/// First-quest explainer extracted from HeroHomeView checklist flow.
struct HeroHomeFirstQuestSheetView: View {
    let onClose: () -> Void
    let onAcknowledge: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(FlavorTextProvider.questCompleteHint)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.top, 32)
                    .padding(.horizontal, 24)
                Text(FlavorTextProvider.questHelpHowTo)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
                Button {
                    onAcknowledge()
                } label: {
                    Text("Got it!")
                        .font(.headline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(DesignSystemConstants.Colors.primaryGreen))
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .navigationTitle("First Quest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onClose() }
                }
            }
        }
    }
}
