//
//  GoalEditorSheet.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// Sheet for creating or editing a savings goal — collects icon, name, category, target amount, and bucket.
struct GoalEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let initialGoal: GoalCache?
    private let onSave: (GoalDraft) async throws -> Void
    private let onDelete: (() async throws -> Void)?

    // MARK: - State

    @State private var selectedEmoji: String?
    @State private var nameText: String
    @State private var categoryText: String
    @State private var targetAmountText: String
    @State private var bucketKind: BucketKind
    @FocusState private var isAmountFocused: Bool
    @State private var isSaving: Bool = false
    @State private var isDeleting: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var parsingError: String?

    init(
        goal: GoalCache? = nil,
        onSave: @escaping (GoalDraft) async throws -> Void,
        onDelete: (() async throws -> Void)? = nil
    ) {
        self.initialGoal = goal
        self.onSave = onSave
        self.onDelete = onDelete
        _selectedEmoji = State(initialValue: goal?.emojiIcon ?? "🎯")
        _nameText = State(initialValue: goal?.name ?? "")
        _categoryText = State(initialValue: goal?.category ?? "")
        if let goal {
            let dollars = Double(goal.targetAmountPennies) / 100.0
            _targetAmountText = State(initialValue: String(format: "%.2f", dollars))
        } else {
            _targetAmountText = State(initialValue: "")
        }
        _bucketKind = State(initialValue: goal?.bucketKindEnum ?? .shortTermSave)
    }

    // MARK: - Curated emoji set (standalone, roughly 40 emoji across themes).

    private static let emojiGrid: [[String]] = [
        ["🎯", "🌟", "🚀", "🎮", "🎸", "🎨", "📚", "🎓"],
        ["🚲", "🧩", "💻", "📱", "🎧", "📸", "🎬", "🎹"],
        ["🏕️", "🎒", "🧸", "🛴", "🏀", "⚽", "🏈", "🎾"],
        ["🐶", "🐱", "🐰", "🦄", "🐉", "🌸", "🌊", "🏔️"],
        ["💰", "💎", "🎁", "🎪", "✈️", "🏰", "🎡", "🛍️"]
    ]

    var body: some View {
        NavigationStack {
            Form {
                emojiPickerSection
                nameSection
                categorySection
                targetAmountSection
                bucketPickerSection

                if onDelete != nil {
                    deleteSection
                }
            }
            .navigationTitle(initialGoal != nil ? "Edit Goal" : "New Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving || isDeleting)
                        .accessibilityIdentifier("goalEditor.cancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveGoal() }
                        .disabled(!isValid || isSaving || isDeleting)
                        .accessibilityIdentifier("goalEditor.saveButton")
                }
            }
            .alert("Delete Goal?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    deleteGoal()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete “\(nameText)”? This action cannot be undone.")
            }
        }
    }

    // MARK: - Emoji Picker

    private var emojiPickerSection: some View {
        Section("Icon") {
            VStack(spacing: 10) {
                ForEach(Self.emojiGrid.indices, id: \.self) { rowIndex in
                    HStack(spacing: 0) {
                        ForEach(Self.emojiGrid[rowIndex], id: \.self) { emoji in
                            Button {
                                selectedEmoji = emoji
                            } label: {
                                Text(emoji)
                                    .font(.title)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(
                                        selectedEmoji == emoji
                                            ? RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.2))
                                            : nil
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Name

    private var nameSection: some View {
        Section("Goal Name") {
            TextField("e.g. New Bike", text: $nameText)
                .submitLabel(.done)
                .accessibilityIdentifier("goalEditor.nameField")
        }
    }

    // MARK: - Category

    private static let categoryChips: [String] = [
        "Toys", "Electronics", "Activities", "Clothes", "Games", "Music", "Sports", "Travel"
    ]

    private var categorySection: some View {
        Section {
            // Category chips row.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.categoryChips, id: \.self) { chip in
                        PresetPill(
                            text: chip,
                            isSelected: categoryText == chip,
                            action: {
                                // Toggle: if already selected, clear; otherwise select.
                                if categoryText == chip {
                                    categoryText = ""
                                } else {
                                    categoryText = chip
                                }
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            // Custom category input.
            TextField("Or type a custom category", text: $categoryText)
        } header: {
            Text("Category (optional)")
        }
    }

    // MARK: - Target Amount

    private var targetAmountSection: some View {
        Section {
            HStack(spacing: 4) {
                // WHY: Use CurrencyFormatter symbol so no "$" literal is hard-coded.
                Text(CurrencyFormatter.currencySymbol)
                    .foregroundStyle(.secondary)

                TextField("0.00", text: $targetAmountText)
                    .keyboardType(.decimalPad)
                    .focused($isAmountFocused)
                    .decimalPadDoneToolbar(isFocused: $isAmountFocused)
                    .accessibilityIdentifier("goalEditor.amountField")
                    .onChange(of: targetAmountText) { _, newValue in
                        validateAmount(newValue)
                    }
            }

            if let error = parsingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
            }
        } header: {
            Text("Target Amount")
        }
    }

    // MARK: - Bucket Picker

    private var bucketPickerSection: some View {
        Section("Savings Bucket") {
            Picker("Bucket", selection: $bucketKind) {
                Text("Short Save")
                    .tag(BucketKind.shortTermSave)
                Text("Long Save")
                    .tag(BucketKind.longTermSave)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Delete Section

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    if isDeleting {
                        ProgressView()
                    } else {
                        Label("Delete Goal", systemImage: "trash")
                            .foregroundStyle(Color(DesignSystemConstants.Colors.dangerRed))
                    }
                    Spacer()
                }
            }
            .disabled(isSaving || isDeleting)
            .accessibilityIdentifier("goalEditor.deleteButton")
        }
    }

    // MARK: - Validation & Save

    private var isValid: Bool {
        !nameText.trimmingCharacters(in: .whitespaces).isEmpty
            && (parsedPennies ?? 0) > 0
    }

    private var parsedPennies: Int64? {
        // WHY: Locale-aware parsing via CurrencyFormatter so comma decimals work and both sheets share one parser.
        guard let dollars = CurrencyFormatter.decimalDouble(from: targetAmountText),
              dollars > 0
        else { return nil }
        return Int64((dollars * 100.0).rounded())
    }

    /// Validates input and surfaces parsing errors as the user types.
    private func validateAmount(_ value: String) {
        guard !value.isEmpty else {
            parsingError = nil
            return
        }
        // WHY: Single-source decimal parsing via CurrencyFormatter — matches BucketTransferView.parsedAmount.
        if CurrencyFormatter.decimalDouble(from: value) == nil {
            parsingError = "Enter a valid dollar amount (e.g. 49.99)."
        } else {
            parsingError = nil
        }
    }

    private func saveGoal() {
        guard let pennies = parsedPennies, isValid else { return }
        let trimmedName = nameText.trimmingCharacters(in: .whitespaces)
        let trimmedCategory = categoryText.trimmingCharacters(in: .whitespaces)
        let finalCategory = trimmedCategory.isEmpty ? nil : trimmedCategory

        let draft = GoalDraft(
            name: trimmedName,
            emojiIcon: selectedEmoji,
            category: finalCategory,
            targetAmountPennies: pennies,
            bucketKind: bucketKind
        )

        isSaving = true
        Task {
            do {
                try await onSave(draft)
                dismiss()
            } catch {
                // Keep sheet open on failure — parent surfaces the error.
                parsingError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                isSaving = false
            }
        }
    }

    private func deleteGoal() {
        guard let onDelete else { return }
        isDeleting = true
        Task {
            do {
                try await onDelete()
                dismiss()
            } catch {
                parsingError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                isDeleting = false
            }
        }
    }
}

// MARK: - GoalDraft

/// Validated goal-creation payload passed to the parent save handler.
struct GoalDraft: Sendable {
    let name: String
    let emojiIcon: String?
    let category: String?
    let targetAmountPennies: Int64
    let bucketKind: BucketKind
}
