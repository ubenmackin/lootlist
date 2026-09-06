//
//  NotificationPrimeView.swift
//  LootList
//
//  Created by Ben Mackin on 9/5/26.
//

import SwiftUI
import UserNotifications

struct NotificationPrimeView: View {
    @Bindable var viewModel: OnboardingViewModel
    @Environment(NotificationService.self) private var notificationService
    @Environment(ToastManager.self) private var toastManager

    @State private var isRequesting = false
    @State private var authorizationStatus: UNAuthorizationStatus?
    @State private var didLoadStatus = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 12)

                illustration

                VStack(spacing: 12) {
                    if !didLoadStatus || authorizationStatus == nil {
                        ProgressView()
                            .tint(Color(DesignSystemConstants.Colors.accentBlue))
                            .accessibilityIdentifier("notificationPrime.loadingIndicator.body")
                    } else if authorizationStatus == .authorized {
                        authorizedContent
                    } else if authorizationStatus == .denied {
                        deniedContent
                    } else {
                        defaultContent
                    }
                }

                Spacer(minLength: 12)

                actionButtons
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(
            LinearGradient(
                colors: [Color(DesignSystemConstants.Colors.background), Color(DesignSystemConstants.Colors.accentBlue).opacity(0.15)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .navigationBarBackButtonHidden(true)
        .task {
            await loadAuthorizationStatus()
        }
    }

    // MARK: - Illustration

    private var illustration: some View {
        ZStack {
            Image(systemName: "shield.fill")
                .font(.system(size: 88, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color(DesignSystemConstants.Colors.accentBlue), Color(DesignSystemConstants.Colors.gold).opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color(DesignSystemConstants.Colors.accentBlue).opacity(0.25), radius: 12, x: 0, y: 6)

            Image(systemName: "bell.badge.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .padding(8)
                .background(
                    Circle()
                        .fill(Color(DesignSystemConstants.Colors.accentBlue))
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                )
                .offset(x: 28, y: 28)
        }
        .frame(height: 120)
        .accessibilityHidden(true)
    }

    // MARK: - Content Variants

    /// Single parameterized prime message so the card-plus-line layout never drifts across auth states.
    private func primeContent(message: String) -> some View {
        VStack(spacing: 16) {
            NotificationPrimeCard()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
    }

    private var defaultContent: some View {
        primeContent(message: "You can change this anytime in Settings.")
    }

    private var authorizedContent: some View {
        primeContent(message: "You're all set! Notifications on.")
    }

    private var deniedContent: some View {
        primeContent(message: "Notifications are off. You can turn them on later in System Settings > Notifications > LootList.")
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionButtons: some View {
        if !didLoadStatus || authorizationStatus == nil {
            ProgressView()
                .tint(Color(DesignSystemConstants.Colors.accentBlue))
                .accessibilityIdentifier("notificationPrime.loadingIndicator.actions")
        } else if authorizationStatus == .authorized {
            Button {
                handleAuthorizedContinue()
            } label: {
                Text("Continue")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(DesignSystemConstants.Colors.accentBlue))
            .disabled(isRequesting)
            .accessibilityIdentifier("notificationPrime.enableButton")
        } else if authorizationStatus == .denied {
            Button {
                handleDeniedContinue()
            } label: {
                Text("Continue")
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(DesignSystemConstants.Colors.accentBlue))
            .disabled(isRequesting)
            .accessibilityIdentifier("notificationPrime.enableButton")

            Text("To enable later, open Settings and allow notifications.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else {
            Button {
                handleEnable()
            } label: {
                HStack(spacing: 8) {
                    if isRequesting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "bell.badge.fill")
                    }
                    Text("Enable Notifications")
                        .font(.headline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(DesignSystemConstants.Colors.accentBlue))
            .disabled(isRequesting)
            .accessibilityIdentifier("notificationPrime.enableButton")

            Button {
                handleSkip()
            } label: {
                Text("Maybe Later")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .disabled(isRequesting)
            .accessibilityIdentifier("notificationPrime.skipButton")
        }
    }

    // MARK: - Handlers

    private func handleEnable() {
        Task { @MainActor in
            isRequesting = true
            defer { isRequesting = false }
            do {
                _ = try await viewModel.enableNotificationsAfterPrime()
                viewModel.skipNotificationPrime()
            } catch let error as NotificationServiceError {
                toastManager.show(message: error.localizedDescription, type: .error)
            } catch {
                let wrapped = NotificationServiceError.centerFailure("\(error)")
                toastManager.show(message: wrapped.localizedDescription, type: .error)
            }
        }
    }

    private func handleSkip() {
        viewModel.skipNotificationPrime()
    }

    private func handleAuthorizedContinue() {
        notificationService.setMasterEnabled(true)
        viewModel.completeNotificationPrime()
    }

    private func handleDeniedContinue() {
        // WHY no master write: the system grant is denied, so the master flag stays off.
        viewModel.completeNotificationPrime()
    }

    // MARK: - Authorization Status

    private func loadAuthorizationStatus() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
        didLoadStatus = true
    }
}
