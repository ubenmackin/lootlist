//
//  SHA256+Hex.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import CryptoKit
import Foundation

extension SHA256.Digest {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    var shortHex: String {
        prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
