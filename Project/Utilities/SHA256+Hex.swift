//
//  SHA256+Hex.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import CryptoKit
import Foundation

extension SHA256.Digest {
    /// WHY single source: every hex rendering shares one formatter so collision suffixes cannot diverge.
    func hexPrefix(_ byteCount: Int) -> String {
        prefix(byteCount).map { String(format: "%02x", $0) }.joined()
    }

    var hex: String {
        // WHY explicit digest length: Digest is a Sequence so bare count binds to count(where:), not element count.
        hexPrefix(SHA256.byteCount)
    }

    var shortHex: String {
        hexPrefix(8)
    }
}
