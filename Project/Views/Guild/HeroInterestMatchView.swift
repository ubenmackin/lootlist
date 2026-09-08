//
//  HeroInterestMatchView.swift
//  LootList
//
//  Created by Ben Mackin on 8/26/26.
//

import os
import SwiftData
import SwiftUI

struct HeroInterestMatchView: View {
    private let logger = Logger(category: "HeroInterestMatch")

    let hero: ProfileCache
    let familyRecordName: String?

    @Query private var heroRows: [ProfileCache]

    @Environment(AppState.self) private var appState
    @Environment(InterestService.self) private var interestService
    @Environment(MatchService.self) private var matchService
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - Interest State

    @State private var interestEnabled: Bool
    @State private var interestBucket: BucketKind
    @State private var interestRatePercent: Double
    @State private var isCompound: Bool

    // MARK: - Match State

    @State private var matchEnabled: Bool
    @State private var matchRatePercent: Double
    @State private var matchCapDollars: String

    @State private var isSaving: Bool = false
    @FocusState private var isCapFocused: Bool

    private var activeHero: ProfileCache {
        heroRows.first ?? hero
    }

    init(hero: ProfileCache, familyRecordName: String? = nil) {
        self.hero = hero
        self.familyRecordName = familyRecordName

        let targetRecord = hero.recordName
        let targetFamily = familyRecordName ?? hero.familyRecordName
        _heroRows = Query(filter: ProfileCache.recordPredicate(recordName: targetRecord, familyRecordName: targetFamily))

        _interestEnabled = State(initialValue: hero.interestEnabled)
        _interestBucket = State(initialValue: hero.interestBucket.flatMap { BucketKind(rawValue: $0) } ?? .longTermSave)
        _interestRatePercent = State(initialValue: hero.interestRateBps > 0 ? Double(hero.interestRateBps) / 100.0 : 5.0)
        _isCompound = State(initialValue: hero.interestIsCompound)

        _matchEnabled = State(initialValue: hero.matchEnabled)
        _matchRatePercent = State(initialValue: hero.matchRateBps > 0 ? Double(hero.matchRateBps) / 100.0 : 100.0)
        if let cap = hero.matchMonthlyCapPennies {
            _matchCapDollars = State(initialValue: CurrencyFormatter.editingString(cap))
        } else {
            _matchCapDollars = State(initialValue: "")
        }
    }

    private var currentInterestRateBps: Int {
        max(0, Int((interestRatePercent * 100).rounded()))
    }

    private var currentMatchRateBps: Int {
        max(0, Int((matchRatePercent * 100).rounded()))
    }

    private var parsedMatchCapPennies: Int64? {
        guard let value = CurrencyFormatter.pennies(from: matchCapDollars), value > 0 else {
            return nil
        }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                heroHeaderSection
                interestSection
                matchSection
            }
            .navigationTitle("Interest & Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                    .fontWeight(.semibold)
                }
            }
            .decimalPadDoneToolbar(isFocused: $isCapFocused)
            .onChange(of: heroRows.first) { _, updatedHero in
                guard let updatedHero, !isSaving else { return }
                interestEnabled = updatedHero.interestEnabled
                interestBucket = updatedHero.interestBucket.flatMap { BucketKind(rawValue: $0) } ?? .longTermSave
                interestRatePercent = updatedHero.interestRateBps > 0 ? Double(updatedHero.interestRateBps) / 100.0 : 5.0
                isCompound = updatedHero.interestIsCompound
                matchEnabled = updatedHero.matchEnabled
                matchRatePercent = updatedHero.matchRateBps > 0 ? Double(updatedHero.matchRateBps) / 100.0 : 100.0
                if let cap = updatedHero.matchMonthlyCapPennies {
                    matchCapDollars = CurrencyFormatter.editingString(cap)
                } else {
                    matchCapDollars = ""
                }
            }
        }
    }

    // MARK: - Header

    private var heroHeaderSection: some View {
        Section {
            HStack(spacing: 12) {
                if let emoji = activeHero.avatarEmoji, !emoji.isEmpty {
                    Text(emoji)
                        .font(.title2)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color(.tertiarySystemGroupedBackground)))
                } else {
                    ProfileAvatarView(profileCache: activeHero)
                        .frame(width: 40, height: 40)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(activeHero.displayName)
                        .font(.headline)
                    Text("Automated growth incentives & savings match")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Monthly Interest Section

    private var interestSection: some View {
        Section {
            Toggle(isOn: $interestEnabled) {
                Label("Pay Monthly Interest", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.subheadline.weight(.semibold))
            }

            if interestEnabled {
                Picker("Deposit Into", selection: $interestBucket) {
                    ForEach(BucketKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }

                HStack {
                    Text("Monthly Rate")
                    Spacer()
                    Stepper(
                        "\(String(format: "%g", interestRatePercent))%",
                        value: $interestRatePercent,
                        in: 0.5 ... 50.0,
                        step: 0.5
                    )
                }

                Toggle("Compound Interest", isOn: $isCompound)

                interestExplainerRow
            }
        } header: {
            Text("Monthly Interest")
        } footer: {
            if interestEnabled {
                Text("Interest is calculated and deposited automatically each month into \(hero.displayName)'s \(interestBucket.displayName) bucket.")
            }
        }
    }

    private var interestExplainerRow: some View {
        let sampleBalance = 20.0
        let monthlyGain = sampleBalance * (interestRatePercent / 100.0)
        return HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
            Text("A \(CurrencyFormatter.string(sampleBalance)) balance earns \(CurrencyFormatter.string(monthlyGain)) each month.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Parent Match Section

    private var matchSection: some View {
        Section {
            Toggle(isOn: $matchEnabled) {
                Label("Match Goal Savings", systemImage: "arrow.trianglehead.branch")
                    .font(.subheadline.weight(.semibold))
            }

            if matchEnabled {
                HStack {
                    Text("Match Rate")
                    Spacer()
                    Stepper(
                        "\(String(format: "%g", matchRatePercent))%",
                        value: $matchRatePercent,
                        in: 10.0 ... 200.0,
                        step: 10.0
                    )
                }

                HStack {
                    Text("Monthly Cap")
                    Spacer()
                    TextField("No Cap", text: $matchCapDollars)
                        .keyboardType(.decimalPad)
                        .focused($isCapFocused)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                }

                matchExplainerRow
            }
        } header: {
            Text("Parent Match")
        } footer: {
            if matchEnabled {
                Text("Whenever \(activeHero.displayName) saves toward a goal, your match is added to help reach their milestone faster.")
            }
        }
    }

    private var matchExplainerRow: some View {
        let sampleSave = 10.0
        let matchAmount = sampleSave * (matchRatePercent / 100.0)
        return HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
            Text("When \(activeHero.displayName) saves \(CurrencyFormatter.string(sampleSave)), you contribute \(CurrencyFormatter.string(matchAmount)).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Helpers & Save

    @MainActor
    private func save() async {
        let zoneID = appState.resolvedFamilyZoneID(fallbackRecord: activeHero)
        isSaving = true
        defer { isSaving = false }

        do {
            let profile = activeHero.toProfile(zoneID: zoneID)
            _ = try await interestService.updateInterestConfig(
                profile: profile,
                enabled: interestEnabled,
                bucket: interestEnabled ? interestBucket : nil,
                rateBps: currentInterestRateBps,
                isCompound: isCompound
            )

            _ = try await matchService.updateMatchConfig(
                profile: profile,
                enabled: matchEnabled,
                rateBps: currentMatchRateBps,
                monthlyCapPennies: matchEnabled ? parsedMatchCapPennies : nil
            )

            toastManager.show(message: "\(activeHero.displayName)'s savings settings saved.", type: .success)
            dismiss()
        } catch {
            logger.error("Failed to save interest/match config: \(error, privacy: .private)")
            toastManager.show(
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                type: .error
            )
        }
    }
}
