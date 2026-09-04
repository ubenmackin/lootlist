//
//  ShareAcceptanceBuffer.swift
//  LootList
//
//  Created by Ben Mackin on 9/3/26.
//

import Foundation
import Synchronization

/// Replay store for CloudKit share acceptances that arrive before the SwiftUI
/// scene subscribes to `.cloudKitShareAccepted`.
enum ShareAcceptanceBuffer {
    private struct State: Sendable {
        var order: [String] = []
        var entries: [String: InvitationLinkResolution] = [:]
    }

    private static let pending = Mutex<State>(State())
    private static let maxBuffered = 5

    static func enqueue(_ resolution: InvitationLinkResolution) {
        let key = resolution.shareRecordName
        pending.withLock { state in
            // WHY: scene and app-delegate callbacks can deliver the same acceptance twice, so the replay fires once per share.
            if state.entries[key] != nil {
                state.order.removeAll { $0 == key }
            } else if state.order.count >= maxBuffered, let oldest = state.order.first {
                // WHY: cap bounds cold-launch replay when repeated invite taps arrive before the SwiftUI listener subscribes.
                state.order.removeFirst()
                state.entries.removeValue(forKey: oldest)
            }
            state.order.append(key)
            state.entries[key] = resolution
        }
    }

    static func drain() -> [InvitationLinkResolution] {
        pending.withLock { state in
            let resolutions = state.order.compactMap { state.entries[$0] }
            state.order.removeAll()
            state.entries.removeAll()
            return resolutions
        }
    }

    static func remove(_ resolution: InvitationLinkResolution) {
        remove(shareRecordName: resolution.shareRecordName)
    }

    private static func remove(shareRecordName key: String) {
        pending.withLock { state in
            state.entries.removeValue(forKey: key)
            state.order.removeAll { $0 == key }
        }
    }
}
