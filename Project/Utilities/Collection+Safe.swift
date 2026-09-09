//
//  Collection+Safe.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import Foundation

extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
