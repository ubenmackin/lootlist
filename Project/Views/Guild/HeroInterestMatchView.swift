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

    @Query private var heroRows: [ProfileCache]

    @Environment(AppState.self) private var appState
    @Environment(InterestService.self) private var interestService
    @Environment(MatchService.self) private var matchService
    @Environment(ToastManager.self) private var toastManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - Interest State

    @State private var interestEnabled: Bool
    @State private var interestBucket: BucketKind
    @State private var interestRateBps: Int
    @State private var isCompound: Bool

    // MARK: - Match State

    @State private var matchEnabled: Bool
    @State private var matchRateBps: Int
    @State private var matchCapDollars: String

    @State private var isSaving: Bool = false
    @FocusState private var isCapFocused: Bool

    private var activeHero: ProfileCache {
        heroRows.first ?? hero
    }

    init(hero: ProfileCache, familyRecordName: String? = nil) {
        self.hero = hero

        let targetRecord = hero.recordName
        let targetFamily = familyRecordName ?? hero.familyRecordName
        _heroRows = Query(filter: ProfileCache.recordPredicate(recordName: targetRecord, familyRecordName: targetFamily))

        _interestEnabled = State(initialValue: hero.interestEnabled)
        _interestBucket = State(initialValue: hero.interestBucket.flatMap { BucketKind(rawValue: $0) } ?? .longTermSave)
        _interestRateBps = State(initialValue: hero.interestRateBps > 0 ? hero.interestRateBps : 500)
        _isCompound = State(initialValue: hero.interestIsCompound)

        _matchEnabled = State(initialValue: hero.matchEnabled)
        _matchRateBps = State(initialValue: hero.matchRateBps > 0 ? hero.matchRateBps : 10000)
        if let cap = hero.matchMonthlyCapPennies {
            _matchCapDollars = State(initialValue: CurrencyFormatter.editingString(cap))
        } else {
            _matchCapDollars = State(initialValue: "")
        }
    }

    private var currentInterestRateBps: Int {
        max(0, interestRateBps)
    }

    private var currentMatchRateBps: Int {
        max(0, matchRateBps)
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
                        // WHY snapshot: @State values cross suspension; Sendable copies ride the Task.
                        let zoneIDSnapshot = appState.resolvedFamilyZoneID(fallbackRecord: activeHero)
                        let profileSnapshot = activeHero.toProfile(zoneID: zoneIDSnapshot)
                        let interestSnapshot = (enabled: interestEnabled, bucket: interestBucket, rateBps: currentInterestRateBps, compound: isCompound)
                        let matchSnapshot = (enabled: matchEnabled, rateBps: currentMatchRateBps, cap: parsedMatchCapPennies)
                        let displayNameSnapshot = activeHero.displayName
                        // WHY MainActor view: isSaving mutates on the isolated task so Sendable captures stay race-free.
                        Task { @MainActor [interestService, matchService, profileSnapshot, interestSnapshot, matchSnapshot, displayNameSnapshot, toastManager, dismiss, logger] in
                            isSaving = true
                            defer { isSaving = false }
                            do {
                                _ = try await interestService.updateInterestConfig(
                                    profile: profileSnapshot,
                                    enabled: interestSnapshot.enabled,
                                    bucket: interestSnapshot.enabled ? interestSnapshot.bucket : nil,
                                    rateBps: interestSnapshot.rateBps,
                                    isCompound: interestSnapshot.compound
                                )
                                _ = try await matchService.updateMatchConfig(
                                    profile: profileSnapshot,
                                    enabled: matchSnapshot.enabled,
                                    rateBps: matchSnapshot.rateBps,
                                    monthlyCapPennies: matchSnapshot.enabled ? matchSnapshot.cap : nil
                                )
                                toastManager.show(message: "\(displayNameSnapshot)'s savings settings saved.", type: .success)
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
                    .disabled(isSaving)
                    .fontWeight(.semibold)
                }
            }
            .decimalPadDoneToolbar(isFocused: $isCapFocused, amountText: $matchCapDollars)
            .onChange(of: heroRows.first) { _, updatedHero in
                guard let updatedHero, !isSaving else { return }
                interestEnabled = updatedHero.interestEnabled
                interestBucket = updatedHero.interestBucket.flatMap { BucketKind(rawValue: $0) } ?? .longTermSave
                interestRateBps = updatedHero.interestRateBps > 0 ? updatedHero.interestRateBps : 500
                isCompound = updatedHero.interestIsCompound
                matchEnabled = updatedHero.matchEnabled
                matchRateBps = updatedHero.matchRateBps > 0 ? updatedHero.matchRateBps : 10000
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
                        CurrencyFormatter.percentString(bps: interestRateBps),
                        value: $interestRateBps,
                        in: 50 ... 5000,
                        step: 50
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
        let samplePennies: Int64 = 2000
        // WHY single source: preview shares truncate math with InterestService.
        let gainPennies = InterestService.interestPennies(basePennies: samplePennies, rateBps: currentInterestRateBps)
        return HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
            Text("A \(CurrencyFormatter.string(samplePennies)) balance earns \(CurrencyFormatter.string(gainPennies)) each month.")
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
                        CurrencyFormatter.percentString(bps: matchRateBps),
                        value: $matchRateBps,
                        in: 1000 ... 20000,
                        step: 1000
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
        let samplePennies: Int64 = 1000
        // WHY single source: preview shares truncate math with MatchService.
        let matchPennies = MatchService.matchPennies(contributionPennies: samplePennies, rateBps: currentMatchRateBps)
        return HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
            Text("When \(activeHero.displayName) saves \(CurrencyFormatter.string(samplePennies)), you contribute \(CurrencyFormatter.string(matchPennies)).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
