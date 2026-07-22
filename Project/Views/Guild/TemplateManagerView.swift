import SwiftUI
import CloudKit

struct TemplateManagerView: View {

    @Bindable var viewModel: QuestManagerViewModel

    let editing: QuestTemplate?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var descriptionText: String = ""
    @State private var defaultGoldText: String = ""
    @State private var xpRewardText: String = ""
    @State private var schedule: QuestSchedule = .weeklyFlexible
    @State private var specificDays: Set<String> = []
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
                Section("Basics") {
                    TextField("Quest Name", text: $name)
                    TextField("Description", text: $descriptionText, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("Rewards") {
                    HStack {
                        Text("Gold").foregroundStyle(.secondary)
                        Spacer()
                        TextField("0.00", text: $defaultGoldText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("XP").foregroundStyle(.secondary)
                        Spacer()
                        TextField("0", text: $xpRewardText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Schedule") {
                    Picker("Type", selection: $schedule) {
                        ForEach(QuestSchedule.allCases, id: \.self) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    if schedule == .specificDays {
                        ForEach(Array(Self.weekdayCodes.indices), id: \.self) { idx in
                            let code = Self.weekdayCodes[idx]
                            let label = Self.weekdayDisplay[idx]
                            Toggle(label, isOn: Binding(
                                get: { specificDays.contains(code) },
                                set: { isOn in
                                    if isOn { specificDays.insert(code) }
                                    else { specificDays.remove(code) }
                                }
                            ))
                        }
                    } else if schedule == .allOrNothing {
                        Text("Hero must slay every quest in this template's group for any of them to count.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        if isSaving { ProgressView() } else { Text("Save") }
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
        xpRewardText = String(editing.xpReward)
        schedule = editing.scheduleType
        specificDays = Set(editing.specificDays)
        approvalMode = editing.approvalMode
    }

    private func save() {

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationError = "Name is required."
            return
        }
        guard let gold = Double(defaultGoldText.trimmingCharacters(in: .whitespaces)),
              gold >= 0 else {
            validationError = "Gold must be a non-negative number."
            return
        }
        guard let xp = Int(xpRewardText.trimmingCharacters(in: .whitespaces)),
              xp >= 0 else {
            validationError = "XP must be a non-negative integer."
            return
        }
        if schedule == .specificDays && specificDays.isEmpty {
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
