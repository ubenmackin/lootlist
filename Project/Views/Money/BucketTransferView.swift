//
//  BucketTransferView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// Child-initiated reallocation between the three `BucketKind` buckets.
/// Validates sufficient funds on the source bucket, persists ONE deterministic
/// ledger entry (`source = "transfer"`), and fires a rigid haptic on success.
struct BucketTransferView: View {
    @Environment(AppState.self) private var appState
    @Environment(CKSyncEngineCoordinator.self) private var syncCoordinator: CKSyncEngineCoordinator?
    @Environment(ToastManager.self) private var toastManager: ToastManager?
    @Environment(\.dismiss) private var dismiss

    @State private var fromBucket: BucketKind = .spend
    @State private var toBucket: BucketKind = .shortTermSave
    @State private var amountText: String = ""
    @State private var isSaving: Bool = false
    @State private var showConfirmation: Bool = false

    private var bucketService: BucketService {
        BucketService(
            cacheService: appState.cacheService,
            syncCoordinator: syncCoordinator,
            appState: appState
        )
    }

    private var profile: Profile? {
        appState.currentProfile
    }

    private var family: Family? {
        appState.family
    }

    private var balances: [BucketKind: Double] {
        guard let profile, let family else { return [:] }
        return bucketService.bucketBalances(
            profileRecordName: profile.id.recordName,
            familyRecordName: family.id.recordName
        )
    }

    /// Buckets available as the source — everything except the current to-bucket.
    private var fromOptions: [BucketKind] {
        BucketKind.allCases.filter { $0 != toBucket }
    }

    /// Buckets available as the destination — everything except the current from-bucket.
    private var toOptions: [BucketKind] {
        BucketKind.allCases.filter { $0 != fromBucket }
    }

    private var parsedAmount: Double? {
        guard let value = Double(amountText), value.isFinite, value > 0 else { return nil }
        return value
    }

    private var canTransfer: Bool {
        parsedAmount != nil && fromBucket != toBucket && profile != nil && family != nil
    }

    private var sourceAvailable: Double {
        balances[fromBucket] ?? 0
    }

    var body: some View {
        NavigationStack {
            Form {
                fromSection
                toSection
                amountSection
                summarySection
            }
            .formStyle(.grouped)
            .navigationTitle("Move Money")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showConfirmation = true
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Transfer")
                        }
                    }
                    .disabled(!canTransfer || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
            .alert("Confirm Transfer", isPresented: $showConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Move \(formattedConfirmAmount)") {
                    performTransfer()
                }
            } message: {
                Text("Move \(formattedConfirmAmount) from \(fromBucket.displayName) to \(toBucket.displayName)?")
            }
            .toastOverlay()
        }
    }

    // MARK: - Sections

    private var fromSection: some View {
        Section {
            Picker("From", selection: $fromBucket) {
                ForEach(fromOptions, id: \.self) { kind in
                    HStack {
                        Text(kind.displayName)
                        Spacer()
                        Text(balanceText(for: kind))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .tag(kind)
                }
            }
            .pickerStyle(.inline)
        } header: {
            Text("Source Bucket")
        } footer: {
            Text("Available: \(CurrencyFormatter.string(sourceAvailable))")
        }
    }

    private var toSection: some View {
        Section {
            Picker("To", selection: $toBucket) {
                ForEach(toOptions, id: \.self) { kind in
                    HStack {
                        Text(kind.displayName)
                        Spacer()
                        Text(balanceText(for: kind))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .tag(kind)
                }
            }
            .pickerStyle(.inline)
        } header: {
            Text("Destination Bucket")
        } footer: {
            Text("Money you move lands here and stays in this bucket until you move it again.")
        }
    }

    private var amountSection: some View {
        Section {
            HStack {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                TextField("0.00", text: $amountText)
                    .keyboardType(.decimalPad)
                    .font(.body.monospacedDigit())
                    .accessibilityLabel("Transfer amount in dollars")
            }
        } header: {
            Text("Amount")
        } footer: {
            if let amount = parsedAmount, amount > sourceAvailable {
                Text("You only have \(CurrencyFormatter.string(sourceAvailable)) in \(fromBucket.displayName).")
                    .foregroundStyle(Color.red)
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        if let amount = parsedAmount, amount <= sourceAvailable, fromBucket != toBucket {
            Section("Summary") {
                HStack {
                    Text(fromBucket.displayName)
                    Spacer()
                    Text("-\(CurrencyFormatter.string(amount))")
                        .monospacedDigit()
                        .foregroundStyle(Color.red)
                }
                HStack {
                    Text(toBucket.displayName)
                    Spacer()
                    Text("+\(CurrencyFormatter.string(amount))")
                        .monospacedDigit()
                        .foregroundStyle(Color.green)
                }
            }
        }
    }

    // MARK: - Helpers

    private func balanceText(for kind: BucketKind) -> String {
        CurrencyFormatter.string(balances[kind] ?? 0)
    }

    private var formattedConfirmAmount: String {
        guard let amount = parsedAmount else { return "$0.00" }
        return CurrencyFormatter.string(amount)
    }

    // MARK: - Transfer

    private func performTransfer() {
        guard let amount = parsedAmount,
              let profile,
              let family
        else {
            toastManager?.show(message: "Please check your transfer details.", type: .warning)
            return
        }

        isSaving = true
        Task {
            do {
                _ = try await bucketService.transfer(
                    from: fromBucket,
                    to: toBucket,
                    amount: amount,
                    profile: profile,
                    family: family
                )
                isSaving = false
                HapticsService.rigid()
                dismiss()
            } catch let error as BucketServiceError {
                isSaving = false
                toastManager?.show(message: error.localizedDescription, type: .error)
            } catch {
                isSaving = false
                toastManager?.show(message: "Something went wrong. Please try again.", type: .error)
            }
        }
    }
}
