//
//  SendableZoneID.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import CloudKit
import Foundation

// MARK: - SendableZoneID

/// Sendable wrapper for `CKRecordZone.ID`.
///
/// WHY: `CKRecordZone.ID` is not `Sendable` under Swift 6 strict concurrency,
/// yet zone identity must be stored in `Sendable` contexts (e.g. `Mutex<LifecycleFlags>`
/// inside `AppLifecycleCoordinator` and other cross-actor state). Storing the
/// raw `CKRecordZone.ID` in a `Sendable` struct would violate strict concurrency.
/// This wrapper stores the zone's string components (`zoneName` / `ownerName`),
/// which are `Sendable`, preserving equality and hash semantics while allowing
/// safe cross-actor storage without resorting to `@unchecked Sendable` on the
/// CloudKit type itself.
///
/// DRY: This is the single canonical wrapper for zone identity. All lifecycle
/// and scope code should use this type instead of defining private duplicates
/// or extending `CKRecordZone.ID` with `@unchecked Sendable`, so comparisons
/// and hashing remain consistent across `AppState`, `CacheService`, and
/// `AppLifecycleCoordinator`.
struct SendableZoneID: Sendable, Equatable, Hashable {
    // MARK: - Properties

    let zoneName: String
    let ownerName: String

    // MARK: - Initialization

    /// Creates a Sendable wrapper from a `CKRecordZone.ID`.
    init(_ id: CKRecordZone.ID) {
        self.zoneName = id.zoneName
        self.ownerName = id.ownerName
    }

    /// Creates a Sendable wrapper from explicit zone components.
    init(zoneName: String, ownerName: String) {
        self.zoneName = zoneName
        self.ownerName = ownerName
    }

    // MARK: - Conversion

    /// Reconstitutes the underlying `CKRecordZone.ID` from the stored components.
    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
    }
}
