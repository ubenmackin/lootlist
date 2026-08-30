//
//  StreakWidget.swift
//  LootListWidgets
//
//  Created by Ben Mackin on 8/29/26.
//

import SwiftUI
import WidgetKit

struct StreakProvider: TimelineProvider {
    func placeholder(in _: Context) -> StreakEntry {
        StreakEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in _: Context, completion: @escaping (StreakEntry) -> Void) {
        let snapshot = WidgetDataBridge.loadSnapshot()
        completion(StreakEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<StreakEntry>) -> Void) {
        let snapshot = WidgetDataBridge.loadSnapshot()
        let entry = StreakEntry(date: Date(), snapshot: snapshot)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct StreakEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct StreakWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: StreakEntry

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
        let streak = entry.snapshot.dailyQuestStreak
        return ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: "flame.fill")
                    .font(.caption)
                Text("\(streak)")
                    .font(.headline.weight(.bold))
                    .monospacedDigit()
            }
        }
    }

    private var inlineView: some View {
        let streak = entry.snapshot.dailyQuestStreak
        let savingsStreak = entry.snapshot.weeklySavingsStreak
        return HStack(spacing: 4) {
            Image(systemName: "flame.fill")
            Text("\(streak)-Day Streak · \(savingsStreak)w Save")
        }
    }

    private var rectangularView: some View {
        let streak = entry.snapshot.dailyQuestStreak
        let savings = entry.snapshot.weeklySavingsStreak
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "flame.fill")
                    .font(.caption2)
                Text("HERO STREAKS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(streak)")
                        .font(.headline.weight(.bold))
                    Text("Day Streak")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(savings)")
                        .font(.headline.weight(.bold))
                    Text("Weeks Saved")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct StreakWidget: Widget {
    let kind: String = "StreakWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StreakProvider()) { entry in
            StreakWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Hero Streaks")
        .description("Track your quest and savings streaks.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}
