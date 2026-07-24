import CloudKit
import SwiftUI

struct QuestAssignmentView: View {
    @Bindable var viewModel: QuestManagerViewModel

    @Environment(\.dismiss) private var dismiss

    @State private var assignmentMode: AssignmentMode = .fromTemplate

    // From Template state
    @State private var selectedTemplate: QuestTemplate?
    @State private var selectedHero: Profile?
    @State private var goldOverrideText: String = ""
    @State private var xpOverrideText: String = ""
    @State private var approvalOverride: ApprovalModeSelection = .useTemplate
    @State private var weekOf: Date = defaultWeekOf()

    // Quick Create state
    @State private var quickName: String = ""
    @State private var quickDescription: String = ""
    @State private var quickGoldText: String = "1.00"
    @State private var quickRarity: QuestRarity = .common
    @State private var quickSchedule: QuestSchedule = .weeklyFlexible
    @State private var quickSpecificDays: Set<String> = []
    @State private var quickApproval: ApprovalMode = .autoApprove

    @State private var validationError: String?
    @State private var isSubmitting: Bool = false

    enum AssignmentMode: String, CaseIterable, Identifiable {
        case fromTemplate = "From Template"
        case quickCreate = "Quick Create (One-Off)"
        var id: String {
            rawValue
        }
    }

    enum ApprovalModeSelection: String, CaseIterable, Identifiable {
        case useTemplate = "Use Template Default"
        case autoApproveOverride = "Auto-Approve (override)"
        case parentVerifyOverride = "Parent Verifies (override)"
        var id: String {
            rawValue
        }
    }

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
                Section {
                    Picker("Creation Mode", selection: $assignmentMode) {
                        ForEach(AssignmentMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if assignmentMode == .fromTemplate {
                    templateAssignmentSections
                } else {
                    quickCreateSections
                }

                Section("Week Of") {
                    DatePicker("Week Starting Monday",
                               selection: $weekOf,
                               displayedComponents: .date)
                }

                if let validationError {
                    Section {
                        Text(validationError)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Assign Quest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: submit) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Assign")
                        }
                    }
                    .disabled(isSubmitDisabled)
                }
            }
            .onAppear {
                if selectedTemplate == nil {
                    selectedTemplate = viewModel.templates.first { $0.isActive }
                }
                if selectedHero == nil {
                    selectedHero = viewModel.heroes.first
                }
            }
        }
    }

    @ViewBuilder
    private var templateAssignmentSections: some View {
        Section("Template") {
            if viewModel.templates.filter(\.isActive).isEmpty {
                Text("No active templates. Create one in the Templates tab or use Quick Create.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Template", selection: $selectedTemplate) {
                    Text("Choose…").tag(nil as QuestTemplate?)
                    ForEach(viewModel.templates.filter(\.isActive)) { template in
                        Text(template.name).tag(template as QuestTemplate?)
                    }
                }
            }
        }

        Section("Hero") {
            heroPicker
        }

        Section {
            HStack {
                Text("Gold Override")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(selectedTemplate?.defaultGold.mapToText() ?? "",
                          text: $goldOverrideText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }

            HStack {
                Text("XP Override")
                    .foregroundStyle(.secondary)
                Spacer()
                TextField(selectedTemplate?.xpReward.mapToText() ?? "",
                          text: $xpOverrideText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }

            Picker("Approval", selection: $approvalOverride) {
                ForEach(ApprovalModeSelection.allCases) { sel in
                    Text(sel.rawValue).tag(sel)
                }
            }
        } header: {
            Text("Overrides (optional)")
        } footer: {
            Text("Leaving a field blank uses the template's default value.")
        }
    }

    @ViewBuilder
    private var quickCreateSections: some View {
        Section("One-Off Quest Details") {
            TextField("Quest Name (e.g. Wash the Car)", text: $quickName)

            TextField("Description (optional)", text: $quickDescription, axis: .vertical)
                .lineLimit(2 ... 3)
        }

        Section("Hero") {
            heroPicker
        }

        Section("Rewards") {
            HStack {
                Text("Gold Reward")
                Spacer()
                TextField("1.00", text: $quickGoldText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            HStack(spacing: 8) {
                Text("Presets:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                presetPill("$1.00") { quickGoldText = "1.00" }
                presetPill("$2.50") { quickGoldText = "2.50" }
                presetPill("$5.00") { quickGoldText = "5.00" }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Quest Rarity & XP")
                        .font(.subheadline)
                    Spacer()
                    Text("\(quickRarity.xpReward) XP")
                        .font(.subheadline.bold())
                        .foregroundStyle(quickRarity.color)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(QuestRarity.allCases) { rarity in
                            let isSelected = quickRarity == rarity
                            Button {
                                quickRarity = rarity
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

        Section("Schedule & Approval") {
            Picker("Schedule", selection: $quickSchedule) {
                ForEach(QuestSchedule.allCases, id: \.self) { schedule in
                    Text(schedule.displayName).tag(schedule)
                }
            }

            if quickSchedule == .specificDays {
                ForEach(Array(Self.weekdayCodes.indices), id: \.self) { idx in
                    let code = Self.weekdayCodes[idx]
                    let label = Self.weekdayDisplay[idx]
                    Toggle(label, isOn: Binding(
                        get: { quickSpecificDays.contains(code) },
                        set: { isOn in
                            if isOn {
                                quickSpecificDays.insert(code)
                            } else {
                                quickSpecificDays.remove(code)
                            }
                        }
                    ))
                }
            }

            Picker("Approval", selection: $quickApproval) {
                ForEach(ApprovalMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var heroPicker: some View {
        if viewModel.heroes.isEmpty {
            Text("No heroes in the family.")
                .foregroundStyle(.secondary)
        } else {
            Picker("Hero", selection: $selectedHero) {
                Text("Choose…").tag(nil as Profile?)
                ForEach(viewModel.heroes) { hero in
                    Text(hero.displayName).tag(hero as Profile?)
                }
            }
        }
    }

    private func presetPill(_ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.caption.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    private var isSubmitDisabled: Bool {
        if isSubmitting || selectedHero == nil {
            return true
        }
        if assignmentMode == .fromTemplate {
            return selectedTemplate == nil
        } else {
            return quickName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func submit() {
        guard let hero = selectedHero else {
            validationError = "Select a hero."
            return
        }

        if assignmentMode == .fromTemplate {
            submitFromTemplate(hero: hero)
        } else {
            submitQuickCreate(hero: hero)
        }
    }

    private func submitFromTemplate(hero: Profile) {
        guard let template = selectedTemplate else {
            validationError = "Select a template."
            return
        }

        let gold: Double? = Double(goldOverrideText.trimmingCharacters(in: .whitespaces))
        let xp: Int? = Int(xpOverrideText.trimmingCharacters(in: .whitespaces))
        let approval: ApprovalMode? = switch approvalOverride {
        case .useTemplate: nil
        case .autoApproveOverride: .autoApprove
        case .parentVerifyOverride: .parentVerify
        }

        isSubmitting = true
        Task {
            do {
                try await viewModel.assignQuest(
                    template: template,
                    assignee: hero,
                    goldOverride: gold,
                    xpOverride: xp,
                    approvalOverride: approval,
                    weekOf: weekOf
                )
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                validationError = error.localizedDescription
            }
        }
    }

    private func submitQuickCreate(hero: Profile) {
        let trimmedName = quickName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else {
            validationError = "Quest name is required."
            return
        }

        guard let gold = Double(quickGoldText.trimmingCharacters(in: .whitespaces)), gold >= 0 else {
            validationError = "Gold reward must be a valid non-negative number."
            return
        }

        let xp = quickRarity.xpReward

        if quickSchedule == .specificDays, quickSpecificDays.isEmpty {
            validationError = "Select at least one day for specific-days schedule."
            return
        }

        isSubmitting = true
        Task {
            do {
                try await viewModel.assignQuickQuest(
                    name: trimmedName,
                    description: quickDescription,
                    assignee: hero,
                    goldReward: gold,
                    xpReward: xp,
                    scheduleType: quickSchedule,
                    specificDays: Array(quickSpecificDays),
                    approvalMode: quickApproval,
                    weekOf: weekOf
                )
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                validationError = error.localizedDescription
            }
        }
    }

    private static func defaultWeekOf() -> Date {
        let cal = Calendar.iso8601UTC
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return cal.date(from: comps) ?? Date()
    }
}

private extension Double {
    func mapToText() -> String {
        String(format: "%.2f", self)
    }
}

private extension Int {
    func mapToText() -> String {
        String(self)
    }
}
