//
//  NumberFormatter+Gold.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

extension NumberFormatter {
    static let goldFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}
