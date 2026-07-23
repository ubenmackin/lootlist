import CloudKit
import SwiftUI

struct TemplateManagerView: View {
    @Bindable var viewModel: QuestManagerViewModel

    let editing: QuestTemplate?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var descriptionText: String = ""
    @State private var defaultGoldText: String = ""
    @State private var selectedRarity: QuestRarity = .common
    @State private var schedule: QuestSchedule = .weeklyFlexible
    @State private var specificDays: Set<String> = []
    @State private var isAllOrNothing: Bool = false
    @State private var approvalMode: ApprovalMode = .autoApprove
    @State private var validationError: String?
    @State private var isSaving: Bool = false

    private static let weekdayCodes: [String] = [
        "sunday", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday"
    ]

    private static let weekdayDisplay: [String] = [
        "Sunday", "Monday", "Tuesday", "Wednesday",
        "Thursday", "Friday", "Saturday"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Basic Info") {
                    TextField("Quest Name", text: $name)
                    TextField("Description", text: $descriptionText, axis: .vertical)
                        .lineLimit(2...4)
                }

                Section("Rewards") {
                    HStack {
                        Text("Gold Reward")
                        Spacer()
                        TextField("0.00", text: $defaultGoldText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Quest Rarity & XP")
                                .font(.subheadline)
                            Spacer()
                            Text("\(selectedRarity.xpReward) XP")
                                .font(.subheadline.bold())
                                .foregroundStyle(selectedRarity.color)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(QuestRarity.allCases) { rarity in
                                    let isSelected = selectedRarity == rarity
                                    Button {
                                        selectedRarity = rarity
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: rarity.iconSystemName)
                                                .font(.caption)
                                            Text("\(rarity.rawValue) (\(rarity.xpReward) XP)")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            Capsule()
                                                .fill(isSelected ? rarity.color : rarity.color.opacity(0.12))
                                        )
                                        .foregroundStyle(isSelected ? Color.white : rarity.color)
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(rarity.color.opacity(0.4), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Schedule") {
                    Picker("Type", selection: $schedule) {
                        ForEach(QuestSchedule.allCases, id: \.self) { questSchedule in
                            Text(questSchedule.displayName).tag(questSchedule)
                        }
                    }
                    if schedule == .specificDays {
                        ForEach(Array(Self.weekdayCodes.indices), id: \.self) { idx in
                            let code = Self.weekdayCodes[idx]
                            let label = Self.weekdayDisplay[idx]
                            Toggle(label, isOn: Binding(
                                get: { specificDays.contains(code) },
                                set: { isOn in
                                    if isOn {
                                        specificDays.insert(code)
                                    } else {
                                        specificDays.remove(code)
                                    }
                                }
                            ))
                        }
                    }
                }

                Section("Approval") {
                    Picker("Mode", selection: $approvalMode) {
                        ForEach(ApprovalMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if let validationError {
                    Section {
                        Text(validationError)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(editing == nil ? "New Template" : "Edit Template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: save) {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .onAppear(perform: hydrateFromEditing)
        }
    }

    private func hydrateFromEditing() {
        guard let editing else { return }
        name = editing.name
        descriptionText = editing.description
        defaultGoldText = String(format: "%.2f", editing.defaultGold)
        selectedRarity = editing.rarity
        schedule = editing.scheduleType
        specificDays = Set(editing.specificDays)
        isAllOrNothing = editing.isAllOrNothing
        approvalMode = editing.approvalMode
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationError = "Name is required."
            return
        }
        guard let gold = Double(defaultGoldText.trimmingCharacters(in: .whitespaces)),
              gold >= 0
        else {
            validationError = "Gold must be a non-negative number."
            return
        }
        let xp = selectedRarity.xpReward
        if schedule == .specificDays, specificDays.isEmpty {
            validationError = "Pick at least one day for Specific-Days schedule."
            return
        }

        isSaving = true
        Task {
            do {
                if let editing {
                    var updated = editing
                    updated.name = trimmedName
                    updated.description = descriptionText
                    updated.defaultGold = gold
                    updated.xpReward = xp
                    updated.scheduleType = schedule
                    updated.specificDays = schedule.requiresSpecificDays
                        ? Array(specificDays)
                        : []
                    updated.isAllOrNothing = isAllOrNothing
                    updated.approvalMode = approvalMode
                    try await viewModel.updateTemplate(updated)
                } else {
                    try await viewModel.createTemplate(
                        name: trimmedName,
                        description: descriptionText,
                        defaultGold: gold,
                        xpReward: xp,
                        schedule: schedule,
                        specificDays: schedule.requiresSpecificDays
                            ? Array(specificDays)
                            : [],
                        isAllOrNothing: isAllOrNothing,
                        approvalMode: approvalMode
                    )
                }
                isSaving = false
                dismiss()
            } catch {
                isSaving = false
                validationError = error.localizedDescription
            }
        }
    }
}
