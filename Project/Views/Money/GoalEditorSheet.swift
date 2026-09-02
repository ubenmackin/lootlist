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
    @State private var hasTargetDate: Bool
    @State private var targetDate: Date
    @State private var linkURLText: String
    @State private var resolvedTitle: String?
    @State private var resolvedImageURL: String?
    @State private var isResolvingLink: Bool = false
    @State private var suggestedPrice: ExtractedPrice?
    @State private var isExtractingPrice: Bool = false
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
            _hasTargetDate = State(initialValue: goal.targetDate != nil)
            _targetDate = State(initialValue: goal.targetDate ?? Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date())
            _linkURLText = State(initialValue: goal.linkURL ?? "")
            _resolvedImageURL = State(initialValue: goal.imageURL)
            _resolvedTitle = State(initialValue: nil)
        } else {
            _targetAmountText = State(initialValue: "")
            _hasTargetDate = State(initialValue: false)
            _targetDate = State(initialValue: Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date())
            _linkURLText = State(initialValue: "")
            _resolvedImageURL = State(initialValue: nil)
            _resolvedTitle = State(initialValue: nil)
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

    private static let flatEmojis: [String] = emojiGrid.flatMap(\.self)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.large) {
                    emojiPickerSection
                    nameSection
                    targetAmountSection
                    bucketPickerSection
                    categorySection
                    targetDateSection
                    wishlistLinkSection

                    if onDelete != nil {
                        deleteSection
                    }
                }
                .padding(.horizontal, DesignSystemConstants.Padding.standard)
                .padding(.vertical, DesignSystemConstants.Padding.standard)
            }
            .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
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
            .decimalPadDoneToolbar(isFocused: $isAmountFocused)
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

    // MARK: - Card Background Helper

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
            .fill(Color(DesignSystemConstants.Colors.cardSurface))
    }

    // MARK: - Emoji Picker

    private var emojiPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ICON")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 8) {
                ForEach(Self.flatEmojis, id: \.self) { emoji in
                    Button {
                        selectedEmoji = emoji
                    } label: {
                        Text(emoji)
                            .font(.title)
                            .padding(.vertical, 4)
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
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
    }

    // MARK: - Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GOAL NAME")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 8) {
                TextField("e.g. New Bike", text: $nameText)
                    .submitLabel(.done)
                    .accessibilityIdentifier("goalEditor.nameField")

                if let title = resolvedTitle, !title.isEmpty, nameText.isEmpty {
                    Button {
                        nameText = title
                    } label: {
                        Label("Use “\(title)” from link", systemImage: "arrow.up.left")
                            .font(.caption)
                            .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                    }
                }
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
    }

    // MARK: - Target Amount

    private var targetAmountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TARGET AMOUNT")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(CurrencyFormatter.currencySymbol)
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    TextField("0.00", text: $targetAmountText)
                        .font(.headline.monospacedDigit())
                        .keyboardType(.decimalPad)
                        .focused($isAmountFocused)
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
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
    }

    // MARK: - Bucket Picker

    private var bucketPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SAVINGS BUCKET")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            Picker("Bucket", selection: $bucketKind) {
                Text("Short Save")
                    .tag(BucketKind.shortTermSave)
                Text("Long Save")
                    .tag(BucketKind.longTermSave)
            }
            .pickerStyle(.segmented)
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
    }

    // MARK: - Category

    private static let categoryChips: [String] = [
        "Toys", "Electronics", "Activities", "Clothes", "Games", "Music", "Sports", "Travel"
    ]

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CATEGORY (OPTIONAL)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Self.categoryChips, id: \.self) { chip in
                            PresetPill(
                                text: chip,
                                isSelected: categoryText == chip,
                                action: {
                                    if categoryText == chip {
                                        categoryText = ""
                                    } else {
                                        categoryText = chip
                                    }
                                }
                            )
                        }
                    }
                }
                .frame(height: 36)

                TextField("Or type a custom category", text: $categoryText)
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
    }

    // MARK: - Target Date & Pacing

    private var targetDateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TARGET DATE & PACING (OPTIONAL)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Set Target Date", isOn: $hasTargetDate)

                if hasTargetDate {
                    DatePicker(
                        "Target Date",
                        selection: $targetDate,
                        in: Date()...,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            PresetPill(text: "1 Month", isSelected: isPresetMatching(months: 1)) {
                                setPresetDate(months: 1)
                            }
                            PresetPill(text: "3 Months", isSelected: isPresetMatching(months: 3)) {
                                setPresetDate(months: 3)
                            }
                            PresetPill(text: "6 Months", isSelected: isPresetMatching(months: 6)) {
                                setPresetDate(months: 6)
                            }
                        }
                    }
                    .frame(height: 36)

                    if let pennies = parsedPennies, pennies > 0 {
                        if let summary = GoalPacingCalculator.calculatePacing(
                            targetAmountPennies: pennies,
                            savedPennies: 0,
                            createdAt: initialGoal?.createdAt ?? Date(),
                            targetDate: targetDate
                        ) {
                            HStack(spacing: 8) {
                                Image(systemName: "speedometer")
                                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                                Text("Save \(CurrencyFormatter.string(summary.weeklyRequiredSavingsDollars))/week (\(summary.weeksRemaining) weeks)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
    }

    // MARK: - Wishlist Link

    private var wishlistLinkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WISHLIST WEB LINK (OPTIONAL)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    TextField("https://amazon.com/... or product link", text: $linkURLText)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: linkURLText) { _, newURL in
                            resolveURLMetadata(newURL)
                        }

                    if !linkURLText.isEmpty {
                        Button {
                            linkURLText = ""
                            resolvedTitle = nil
                            resolvedImageURL = nil
                            suggestedPrice = nil
                            isExtractingPrice = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let imageString = resolvedImageURL,
                   let imageURL = URL(string: imageString)
                {
                    HStack(spacing: 10) {
                        AsyncImage(url: imageURL) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                                    .frame(width: 40, height: 40)
                                    .background(Color(DesignSystemConstants.Colors.cardSurface))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            case let .success(image):
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 40, height: 40)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            case .failure:
                                Text(selectedEmoji ?? "🎯")
                                    .font(.title3)
                                    .frame(width: 40, height: 40)
                                    .background(Color(DesignSystemConstants.Colors.cardSurface))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            @unknown default:
                                Color(DesignSystemConstants.Colors.cardSurface)
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                        }
                        .frame(width: 40, height: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            if let title = resolvedTitle, !title.isEmpty {
                                Text(title)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                            }
                            Text(imageURL.host?.replacingOccurrences(of: "www.", with: "") ?? "Preview")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                if isResolvingLink {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Fetching product details...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let url = LinkMetadataService.normalizeURL(from: linkURLText) {
                    HStack {
                        Text("Store: \(url.host?.replacingOccurrences(of: "www.", with: "") ?? "Web Link")")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                            .font(.caption)
                    }
                }

                if isExtractingPrice {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Checking price...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let suggested = suggestedPrice {
                    Button {
                        targetAmountText = String(format: "%.2f", suggested.amount)
                        validateAmount(targetAmountText)
                    } label: {
                        Label("Use suggested price \(CurrencyFormatter.string(suggested.amount))", systemImage: "dollarsign.circle.fill")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Color(DesignSystemConstants.Colors.primaryGreen))
                    .accessibilityIdentifier("goalEditor.useSuggestedPriceButton")
                }
            }
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
    }

    // MARK: - Delete Section

    private var deleteSection: some View {
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
            .padding(DesignSystemConstants.Padding.medium)
            .background(cardBackground)
        }
        .disabled(isSaving || isDeleting)
        .accessibilityIdentifier("goalEditor.deleteButton")
    }

    // MARK: - Validation & Save

    private var isValid: Bool {
        !nameText.trimmingCharacters(in: .whitespaces).isEmpty
            && (parsedPennies ?? 0) > 0
    }

    private var parsedPennies: Int64? {
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
        if CurrencyFormatter.decimalDouble(from: value) == nil {
            parsingError = "Enter a valid dollar amount (e.g. 49.99)."
        } else {
            parsingError = nil
        }
    }

    private func isPresetMatching(months: Int) -> Bool {
        guard let candidate = Calendar.current.date(byAdding: .month, value: months, to: Date()) else { return false }
        return Calendar.current.isDate(candidate, inSameDayAs: targetDate)
    }

    private func setPresetDate(months: Int) {
        if let target = Calendar.current.date(byAdding: .month, value: months, to: Date()) {
            targetDate = target
        }
    }

    private func resolveURLMetadata(_ rawURL: String) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = LinkMetadataService.normalizeURL(from: trimmed) else {
            resolvedTitle = nil
            resolvedImageURL = nil
            suggestedPrice = nil
            isExtractingPrice = false
            return
        }

        isResolvingLink = true
        suggestedPrice = nil
        isExtractingPrice = false
        resolvedImageURL = nil
        Task { @MainActor in
            if let metadata = await LinkMetadataService.fetchMetadata(for: url) {
                if let title = metadata.title, !title.isEmpty {
                    resolvedTitle = title
                    if nameText.isEmpty {
                        nameText = title
                    }
                } else {
                    resolvedTitle = nil
                }
                resolvedImageURL = metadata.imageURL.flatMap { $0.isEmpty ? nil : $0 }
            } else {
                resolvedTitle = nil
                resolvedImageURL = nil
            }
            isResolvingLink = false

            // One-time price suggestion — only when amount is empty, never auto-overwrite.
            let amountEmpty = targetAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if amountEmpty {
                isExtractingPrice = true
                suggestedPrice = nil
                if let price = await PriceExtractionService.extractPrice(from: url) {
                    // Re-check emptiness — user may have typed while fetch was in flight.
                    if targetAmountText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        suggestedPrice = price
                    }
                }
                isExtractingPrice = false
            }
        }
    }

    private func saveGoal() {
        guard let pennies = parsedPennies, isValid else { return }
        let trimmedName = nameText.trimmingCharacters(in: .whitespaces)
        let trimmedCategory = categoryText.trimmingCharacters(in: .whitespaces)
        let finalCategory = trimmedCategory.isEmpty ? nil : trimmedCategory
        let trimmedLink = linkURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLink = trimmedLink.isEmpty ? nil : trimmedLink

        let draft = GoalDraft(
            name: trimmedName,
            emojiIcon: selectedEmoji,
            category: finalCategory,
            targetAmountPennies: pennies,
            bucketKind: bucketKind,
            targetDate: hasTargetDate ? targetDate : nil,
            linkURL: finalLink,
            imageURL: resolvedImageURL
        )

        isSaving = true
        Task { @MainActor in
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
        Task { @MainActor in
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
    var targetDate: Date?
    var linkURL: String?
    var imageURL: String?
}
