//
//  NotificationToken.swift
//  LootList
//
//  Created by Ben Mackin on 8/22/26.
//

import Foundation

/// A Sendable wrapper around an opaque NotificationCenter observer token that
/// automatically unregisters on deallocation. Holding this as a property removes
/// the need for `nonisolated(unsafe)` observer tokens and manual removal in `deinit`.
final class NotificationToken: @unchecked Sendable {
    private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
