//
//  LootListWidgetBundle.swift
//  LootListWidgets
//
//  Created by Ben Mackin on 8/29/26.
//

import SwiftUI
import WidgetKit

@main
struct LootListWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuestProgressWidget()
        StreakWidget()
    }
}
