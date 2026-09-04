//
//  MultiPartQuestCard.swift
//  LootList
//
//  Created by Ben Mackin on 8/31/26.
//

import SwiftUI

struct MultiPartQuestCard: View {
    let quest: QuestCache
    var logs: [QuestCompletionCache] = []
    var specificDays: [String] = []
    var subtitle: String?
    let amountText: String
    var isSubmitting: Bool = false
    var onCompleteSubPart: ((Int) -> Void)?
    var onWithdraw: ((QuestCompletionCache) -> Void)?
    var accessibilityID: String?

    @State private var isExpanded: Bool = true

    // WHY: shared so per-row time labels avoid per-evaluation allocation.
    private static let completionTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private var orderedDays: [String] {
        SpecificDaysHelper.orderedDays(specificDays)
    }

    private var isDayChecklist: Bool {
        SpecificDaysHelper.isDayChecklist(quest: quest, specificDays: specificDays)
    }

    private var todayCode: String {
        WeekMath.todayWeekdayCode()
    }

    private var targetCount: Int {
        SpecificDaysHelper.effectiveTarget(for: quest, specificDays: specificDays)
    }

    private var headerDayState: String {
        SpecificDaysHelper.headerDayState(orderedDays: orderedDays, todayCode: todayCode)
    }

    private var approvedLogs: [QuestCompletionCache] {
        logs.filter(\.isApproved).sorted { $0.completedDate < $1.completedDate }
    }

    private var approvedCount: Int {
        approvedLogs.count
    }

    private var isFullyCompleted: Bool {
        GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approvedCount, effectiveTarget: targetCount)
    }

    private var pendingLog: QuestCompletionCache? {
        logs.first { $0.verificationStatusEnum == .pending }
    }

    private var isPendingReview: Bool {
        !isFullyCompleted && pendingLog != nil
    }

    private var completedSubParts: Int {
        min(targetCount, approvedCount)
    }

    private var approvalMode: ApprovalMode {
        quest.approvalModeEnum ?? .autoApprove
    }

    private func partName(for index: Int) -> String {
        // WHY: day checklist ticks one weekday per approval, so rows read as days not ordinals.
        if isDayChecklist, index < orderedDays.count {
            return WeekMath.shortName(for: orderedDays[index])
        }
        return "\(FlavorTextProvider.ordinal(index + 1)) Time"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            headerButton

            segmentedProgressBar

            if isExpanded {
                subPartsList
            }
        }
        .clipped()
        .padding(DesignSystemConstants.Padding.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay {
            if isPendingReview {
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                    .strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.45), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifierIfSet(accessibilityID)
    }

    // MARK: - Header

    private var headerButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(alignment: .top, spacing: DesignSystemConstants.Padding.medium) {
                headerLeadingIcon

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 6) {
                        Text(quest.questName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isFullyCompleted ? .secondary : .primary)
                            .strikethrough(isFullyCompleted, color: .secondary.opacity(0.5))
                            .lineLimit(2)

                        progressBadge
                    }

                    if let headerSubtitle {
                        Text(headerSubtitle)
                            .font(.caption)
                            .foregroundStyle(subtitleColor)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: DesignSystemConstants.Padding.small)

                Text(amountText)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(isFullyCompleted ? Color(DesignSystemConstants.Colors.primaryGreen) : Color(DesignSystemConstants.Colors.pendingAmber))

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(quest.questName), \(completedSubParts) of \(targetCount) completed")
        .accessibilityHint("Tap to expand or collapse sub-parts")
    }

    @ViewBuilder
    private var headerLeadingIcon: some View {
        if isFullyCompleted {
            ZStack {
                Circle()
                    .fill(Color(DesignSystemConstants.Colors.primaryGreen))
                    .frame(width: 32, height: 32)
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }
        } else if isPendingReview {
            ZStack {
                Circle()
                    .fill(Color(DesignSystemConstants.Colors.pendingAmber))
                    .frame(width: 32, height: 32)
                Image(systemName: "clock.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }
        } else {
            ZStack {
                Circle()
                    .fill(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.16))
                    .frame(width: 32, height: 32)
                Image(systemName: completedSubParts > 0 ? "checklist.checked" : "checklist")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
            }
        }
    }

    private var progressBadge: some View {
        Text("\(completedSubParts)/\(targetCount)")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(isFullyCompleted
                        ? Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.18)
                        : (isPendingReview ? Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.18) : Color.secondary.opacity(0.15)))
            )
            .foregroundStyle(isFullyCompleted
                ? Color(DesignSystemConstants.Colors.primaryGreen)
                : (isPendingReview ? Color(DesignSystemConstants.Colors.pendingAmber) : .secondary))
    }

    private var headerSubtitle: String? {
        if isFullyCompleted {
            return "Completed"
        }
        if isPendingReview {
            // WHY: day state stays visible while awaiting review so hero knows which day is queued.
            if isDayChecklist {
                return "\(headerDayState) · Waiting for Parent Review"
            }
            return "All times done · Waiting for Parent Review"
        }
        // WHY: day state always shows so Due Today versus Due Wed is visible at a glance.
        if isDayChecklist {
            if let subtitle, !subtitle.isEmpty {
                return "\(subtitle) · \(headerDayState) · \(completedSubParts) of \(targetCount) days done"
            }
            return "\(headerDayState) · \(completedSubParts) of \(targetCount) days done"
        }
        if let subtitle {
            return "\(subtitle) · \(completedSubParts) of \(targetCount) times done"
        }
        return "\(completedSubParts) of \(targetCount) times done"
    }

    // MARK: - Segmented Progress Bar

    private var segmentedProgressBar: some View {
        HStack(spacing: 4) {
            ForEach(0 ..< targetCount, id: \.self) { index in
                Capsule()
                    .fill(segmentColor(for: index))
                    .frame(height: 5)
            }
        }
        .padding(.vertical, 2)
    }

    private func segmentColor(for index: Int) -> Color {
        if index < completedSubParts {
            Color(DesignSystemConstants.Colors.primaryGreen)
        } else if isPendingReview, index == completedSubParts {
            Color(DesignSystemConstants.Colors.pendingAmber)
        } else {
            Color.secondary.opacity(0.2)
        }
    }

    // MARK: - Sub-Parts List

    private var subPartsList: some View {
        VStack(spacing: 6) {
            Divider()
                .padding(.vertical, 2)

            ForEach(0 ..< targetCount, id: \.self) { index in
                subPartRow(index: index)
            }
        }
    }

    @ViewBuilder
    private func subPartRow(index: Int) -> some View {
        let isDone = index < completedSubParts
        let isNext = index == completedSubParts && !isPendingReview && !isFullyCompleted
        let isPendingThisSlot = isPendingReview && index == completedSubParts
        let isLocked = index > completedSubParts
        let canUndo = isDone && index == completedSubParts - 1 && index < approvedLogs.count

        HStack(spacing: DesignSystemConstants.Padding.medium) {
            subPartIcon(isDone: isDone, isNext: isNext, isPending: isPendingThisSlot, isLocked: isLocked, index: index)

            VStack(alignment: .leading, spacing: 2) {
                Text(partName(for: index))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isDone || isNext || isPendingThisSlot ? .primary : .secondary)

                Text(subPartSubtitle(index: index, isDone: isDone, isNext: isNext, isPending: isPendingThisSlot))
                    .font(.caption2)
                    .foregroundStyle(subPartSubtitleColor(isDone: isDone, isNext: isNext, isPending: isPendingThisSlot))
            }

            Spacer()

            if isNext {
                Button {
                    onCompleteSubPart?(index)
                } label: {
                    Text("Mark Done")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color(DesignSystemConstants.Colors.primaryGreen))
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            } else if canUndo {
                Button {
                    onWithdraw?(approvedLogs[index])
                } label: {
                    Text("Undo")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color.secondary.opacity(0.15))
                        )
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if isPendingThisSlot, let log = pendingLog {
                Button {
                    onWithdraw?(log)
                } label: {
                    Text("Unsubmit")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.18))
                        )
                        .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isNext ? Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.06) : Color.clear)
        )
    }

    @ViewBuilder
    private func subPartIcon(isDone: Bool, isNext: Bool, isPending: Bool, isLocked _: Bool, index: Int) -> some View {
        if isDone {
            ZStack {
                Circle()
                    .fill(Color(DesignSystemConstants.Colors.primaryGreen))
                    .frame(width: 26, height: 26)
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
        } else if isPending {
            ZStack {
                Circle()
                    .fill(Color(DesignSystemConstants.Colors.pendingAmber))
                    .frame(width: 26, height: 26)
                Image(systemName: "clock.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            }
        } else if isNext {
            Button {
                onCompleteSubPart?(index)
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 2)
                        .frame(width: 26, height: 26)
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Color.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
        } else {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1.5)
                .frame(width: 26, height: 26)
        }
    }

    private func dayState(for code: String) -> String {
        SpecificDaysHelper.dayState(for: code, todayCode: todayCode)
    }

    private func subPartSubtitle(index: Int, isDone: Bool, isNext: Bool, isPending: Bool) -> String {
        // WHY: every day row keeps its due state so makeup days stay actionable within the week.
        if isDayChecklist, index < orderedDays.count {
            let state = dayState(for: orderedDays[index])
            if isDone {
                if index < approvedLogs.count {
                    let date = approvedLogs[index].completedDate
                    return "\(state) · Completed \(Self.completionTimeFormatter.string(from: date))"
                }
                return "\(state) · Completed"
            }
            if isPending {
                return "\(state) · Sent to Parent for Review"
            }
            return state
        }
        if isDone {
            if index < approvedLogs.count {
                let date = approvedLogs[index].completedDate
                return "Completed \(Self.completionTimeFormatter.string(from: date))"
            }
            return "Completed"
        }
        if isPending {
            return "Sent to Parent for Review"
        }
        if isNext {
            return "Ready to complete"
        }
        return "Complete \(partName(for: index - 1).lowercased()) first"
    }

    private func subPartSubtitleColor(isDone: Bool, isNext: Bool, isPending: Bool) -> Color {
        if isDone {
            return Color(DesignSystemConstants.Colors.primaryGreen)
        }
        if isPending {
            return Color(DesignSystemConstants.Colors.pendingAmber)
        }
        if isNext {
            return .primary
        }
        return .secondary
    }

    // MARK: - Styling Helpers

    private var backgroundColor: Color {
        if isFullyCompleted {
            return Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.08)
        }
        if isPendingReview {
            return Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.08)
        }
        return Color(DesignSystemConstants.Colors.cardSurface)
    }

    private var subtitleColor: Color {
        if isPendingReview {
            return Color(DesignSystemConstants.Colors.pendingAmber)
        }
        return .secondary
    }
}
