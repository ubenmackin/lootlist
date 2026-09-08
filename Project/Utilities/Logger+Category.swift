//
//  Logger+Category.swift
//  LootList
//
//  Created by Ben Mackin on 9/08/26.
//

import Foundation
import os

extension Logger {
    init(category: String, subsystem: String = Bundle.main.bundleIdentifier ?? "LootList") {
        self.init(subsystem: subsystem, category: category)
    }
}
