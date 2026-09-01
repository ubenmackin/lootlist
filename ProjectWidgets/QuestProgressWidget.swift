//
//  QuestProgressWidget.swift
//  LootListWidgets
//
//  Created by Ben Mackin on 8/29/26.
//

import os
import SwiftUI
import WidgetKit

struct QuestProgressProvider: TimelineProvider {
    /// WHY os_signpost: widget snapshot duration is budget-sensitive; signpost instruments hangs in Instruments without logging overhead.
    private static let log = OSLog(subsystem: "com.volcrypt.lootlist", category: "WidgetSnapshot")

    func placeholder(in _: Context) -> QuestProgressEntry {
        QuestProgressEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in _: Context, completion: @escaping (QuestProgressEntry) -> Void) {
        // WHY off-main avoidance: widget snapshot is time-limited; synchronous CacheService fetch on main risks hang. Serve cached UserDefaults snapshot instantly.
        let signpostID = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: "WidgetSnapshot", signpostID: signpostID, "QuestProgress getSnapshot")
        let snapshot = WidgetDataBridge.loadSnapshot()
        let entry = QuestProgressEntry(date: Date(), snapshot: snapshot)
        os_signpost(.end, log: Self.log, name: "WidgetSnapshot", signpostID: signpostID)
        completion(entry)
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<QuestProgressEntry>) -> Void) {
        let signpostID = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: "WidgetSnapshot", signpostID: signpostID, "QuestProgress getTimeline")
        let cachedSnapshot = WidgetDataBridge.loadSnapshot()
        let entry = QuestProgressEntry(date: Date(), snapshot: cachedSnapshot)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        os_signpost(.end, log: Self.log, name: "WidgetSnapshot", signpostID: signpostID)
        completion(timeline)
    }
}

struct QuestProgressEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct QuestProgressWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: QuestProgressEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circularView
        case .accessoryInline:
            inlineView
        case .accessoryRectangular:
            rectangularView
        default:
            circularView
        }
    }

    private var circularView: some View {
        let fraction = entry.snapshot.questProgressFraction
        let done = entry.snapshot.todayCompletedQuests
        let total = entry.snapshot.todayTotalQuests

        return Gauge(value: fraction, in: 0 ... 1) {
            Image(systemName: "checklist")
        } currentValueLabel: {
            if total == 0 {
                Text("0")
                    .font(.headline)
            } else {
                Text("\(done)")
                    .font(.headline.weight(.bold))
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private var inlineView: some View {
        let done = entry.snapshot.todayCompletedQuests
        let total = entry.snapshot.todayTotalQuests
        return HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
            Text("Quests: \(done)/\(total) done")
        }
    }

    private var rectangularView: some View {
        let done = entry.snapshot.todayCompletedQuests
        let total = entry.snapshot.todayTotalQuests
        let next = entry.snapshot.nextQuestTitle ?? "All Quests Complete!"

        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "sparkles")
                    .font(.caption2)
                Text("TODAY'S QUESTS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(done)/\(total)")
                    .font(.caption2.weight(.bold))
            }

            Text(next)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)

            if let goalName = entry.snapshot.activeGoalName {
                Text("Goal: \(goalName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct QuestProgressWidget: Widget {
    let kind: String = "QuestProgressWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuestProgressProvider()) { entry in
            QuestProgressWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Daily Quests")
        .description("Track your daily chore completion progress.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}
