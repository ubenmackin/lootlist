//
//  EquipmentService.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation
import os

enum EquipmentError: LocalizedError, Sendable, Equatable {
    case alreadyOwned
    case levelTooLow(required: Int)
    case insufficientGems(required: Int, current: Int)
    case notOwned

    var errorDescription: String? {
        switch self {
        case .alreadyOwned:
            "You already own this item!"
        case let .levelTooLow(required):
            "Reach Hero Level \(required) to unlock this item!"
        case let .insufficientGems(required, current):
            "Need \(required) gems, but you have \(current) 💎."
        case .notOwned:
            "You must purchase this item before equipping it!"
        }
    }
}

@MainActor
@Observable
final class EquipmentService {
    private let cloudKitService: any CloudKitServiceProtocol
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "Equipment")

    var cacheService: CacheService?
    var appState: AppState?
    var syncCoordinator: CKSyncEngineCoordinator?

    private(set) var revision: Int = 0

    init(cloudKitService: any CloudKitServiceProtocol,
         cacheService: CacheService? = nil,
         appState: AppState? = nil,
         syncCoordinator: CKSyncEngineCoordinator? = nil)
    {
        self.cloudKitService = cloudKitService
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
    }

    // MARK: - Ownership & equipped state (CloudKit-backed Profile fields)

    /// Resolves the authoritative profile from the local cache (the write-through
    /// read store in front of CloudKit). Equipment ownership/equip state lives on
    /// `Profile.ownedEquipment` / `Profile.equippedItems` so it syncs cross-device
    /// and cannot be forged by editing the device-local UserDefaults plist.
    /// Falls back to the passed profile when the cache is unavailable (cold
    /// install before the first CKSyncEngine full-sync pass hydrates the cache).
    private func resolvedProfile(_ profile: Profile) -> Profile? {
        guard let cacheService else { return nil }
        let familyRecordName = profile.family.recordID.recordName
        guard let cached = cacheService.fetchProfile(recordName: profile.id.recordName, family: familyRecordName) else { return nil }
        return cached.toProfile(zoneID: profile.id.zoneID)
    }

    /// Write-through persistence of an equipment mutation: optimistic SwiftData
    /// upsert (0ms UI) + `CKSyncEngineCoordinator` enqueue for CloudKit sync +
    /// `AppState.currentProfile` reconciliation when the active hero changed.
    private func persist(_ profile: Profile) {
        cacheService?.upsertProfile(profile)
        let isOwner = appState?.isZoneOwner ?? false
        syncCoordinator?.enqueueSave(recordID: profile.id, isOwner: isOwner)
        if let appState, let current = appState.currentProfile, current.id == profile.id {
            appState.currentProfile = profile
        }
        revision += 1
    }

    // MARK: - Ownership

    func ownedItemIDs(for profile: Profile) -> Set<String> {
        let current = resolvedProfile(profile) ?? profile
        return Set(current.ownedEquipment)
    }

    func isOwned(item: ShopItem, profile: Profile) -> Bool {
        ownedItemIDs(for: profile).contains(item.id)
    }

    // MARK: - Equipping

    func equippedItemIDs(for profile: Profile) -> [String: String] {
        let current = resolvedProfile(profile) ?? profile
        var dict: [String: String] = [:]
        for itemID in current.equippedItems {
            guard let item = ShopItem.item(withId: itemID) else { continue }
            dict[item.category.rawValue] = itemID
        }
        return dict
    }

    func isEquipped(item: ShopItem, profile: Profile) -> Bool {
        let equipped = equippedItemIDs(for: profile)
        return equipped[item.category.rawValue] == item.id
    }

    func equippedItem(for category: ShopCategory, profile: Profile) -> ShopItem? {
        let equipped = equippedItemIDs(for: profile)
        guard let itemID = equipped[category.rawValue] else { return nil }
        return ShopItem.item(withId: itemID)
    }

    func equippedItems(for profile: Profile) -> [ShopCategory: ShopItem] {
        let equipped = equippedItemIDs(for: profile)
        var result: [ShopCategory: ShopItem] = [:]
        for category in ShopCategory.allCases {
            if let itemID = equipped[category.rawValue], let item = ShopItem.item(withId: itemID) {
                result[category] = item
            }
        }
        return result
    }

    // MARK: - Actions

    func buyItem(
        item: ShopItem,
        profile: Profile,
        gemService: GemService,
        soundManager: SoundManager
    ) async throws {
        guard !isOwned(item: item, profile: profile) else {
            throw EquipmentError.alreadyOwned
        }

        guard profile.level >= item.requiredLevel else {
            throw EquipmentError.levelTooLow(required: item.requiredLevel)
        }

        let currentBalance = gemService.balance(for: profile.id.recordName, familyRecordName: profile.family.recordID.recordName)
        guard currentBalance >= item.gemPrice else {
            throw EquipmentError.insufficientGems(required: item.gemPrice, current: currentBalance)
        }

        // Re-resolve the authoritative profile BEFORE the gem spend so the
        // upsert inside `GemService.spendGems` carries the real owned-equipment
        // list forward — the passed `profile` copy may carry a stale empty
        // list that would otherwise wipe previously-owned items when spendGems
        // upserts its debited copy.
        var current = resolvedProfile(profile) ?? profile

        let success = try await gemService.spendGems(
            amount: item.gemPrice,
            from: current,
            itemID: item.id,
            on: item.name,
            eventKey: "shopPurchase-\(item.id)"
        )
        guard success else {
            throw EquipmentError.insufficientGems(required: item.gemPrice, current: currentBalance)
        }

        // Re-resolve AFTER the spend so the ownership upsert carries the
        // freshly-debited gemsTotal forward (spendGems upserted current with
        // the debit) — never overwrite the debit with a pre-spend gems value.
        current = resolvedProfile(profile) ?? current
        if !current.ownedEquipment.contains(item.id) {
            current.ownedEquipment.append(item.id)
        }
        // Auto-equip: drop any currently-equipped item in the same category, then equip the new one.
        current.equippedItems.removeAll { id in
            ShopItem.item(withId: id)?.category == item.category
        }
        current.equippedItems.append(item.id)

        persist(current)

        logger.info("Successfully purchased \(item.name) for \(item.gemPrice) gems by profile \(profile.displayName)")
        soundManager.play(.shopPurchase)
    }

    func toggleEquip(
        item: ShopItem,
        profile: Profile,
        gemService _: GemService,
        soundManager: SoundManager
    ) async throws {
        guard isOwned(item: item, profile: profile) else {
            throw EquipmentError.notOwned
        }

        if isEquipped(item: item, profile: profile) {
            unequip(category: item.category, profile: profile)
        } else {
            equip(item: item, profile: profile)
        }

        soundManager.play(.equipItem)
    }

    func equip(item: ShopItem, profile: Profile) {
        var current = resolvedProfile(profile) ?? profile
        // One equipped item per category: drop the existing one in this category.
        current.equippedItems.removeAll { id in
            ShopItem.item(withId: id)?.category == item.category
        }
        if !current.equippedItems.contains(item.id) {
            current.equippedItems.append(item.id)
        }
        persist(current)
    }

    func unequip(category: ShopCategory, profile: Profile) {
        var current = resolvedProfile(profile) ?? profile
        current.equippedItems.removeAll { id in
            ShopItem.item(withId: id)?.category == category
        }
        persist(current)
    }
}
