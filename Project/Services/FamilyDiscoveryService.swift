//
//  FamilyDiscoveryService.swift
//  LootList
//
//  Created by Ben Mackin on 8/29/26.
//

import CloudKit
import Foundation
import os

/// Discovery of existing CloudKit family state — private owner zones and shared hero zones.
///
/// Centralizes `discoverPrivateOwnerCandidates`, `discoverSharedHeroCandidates`,
/// `fetchSharedZonesWithBoundedRetry`, `activeSharedHeroProfiles`, `sharedZoneFamily`,
/// `restoreSession` helpers (`isZoneReachable`) and `discoverExistingCloudState`
/// orchestration so `AppState` remains a thin session holder (`authStatus`,
/// `currentProfile`, `family`, `familyZoneID`, `isZoneOwner`). Injected via
/// `AppDependencies` to remove temporal coupling where discovery had to check
/// `authStatus == .checkingCloudData` before running.
actor FamilyDiscoveryService {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "FamilyDiscovery")

    private var logger: Logger {
        Self.logger
    }

    struct DiscoveredFamilyCandidate: Sendable {
        let family: Family
        let profile: Profile
        let zoneID: CKRecordZone.ID
    }

    enum DiscoveryResult: Sendable {
        case owner(DiscoveredFamilyCandidate)
        case hero(DiscoveredFamilyCandidate)
        case none
    }

    // MARK: - Orchestration

    /// Pure discovery — no `authStatus` guard. Caller decides how to apply the result to session state.
    func discoverExistingCloudState(cloudKit: any CloudKitServiceProtocol) async -> DiscoveryResult {
        logger.info("Starting iCloud family discovery...")
        let userRecordID = await resolveCurrentUserRecordID(cloudKit: cloudKit)

        let ownerCandidates = await discoverPrivateOwnerCandidates(
            cloudKit: cloudKit,
            userRecordID: userRecordID
        )
        if ownerCandidates.count == 1, let owner = ownerCandidates.first {
            logger.info("SUCCESS: Detected Guild Master profile '\(owner.profile.displayName, privacy: .private)' in family '\(owner.family.name, privacy: .private)'")
            return .owner(owner)
        }
        if ownerCandidates.count > 1 {
            logger.warning("Rejecting ambiguous owner family discovery for the current iCloud account")
        }

        let heroCandidates = await discoverSharedHeroCandidates(
            cloudKit: cloudKit,
            userRecordID: userRecordID
        )
        if heroCandidates.count == 1, let hero = heroCandidates.first {
            logger.info("SUCCESS: Detected Hero profile '\(hero.profile.displayName, privacy: .private)' in shared family '\(hero.family.name, privacy: .private)'")
            return .hero(hero)
        }
        if heroCandidates.count > 1 {
            logger.warning("Rejecting ambiguous hero family discovery for the current iCloud account")
        }

        logger.info("Discovery complete — no active family detected. Transitioning to onboarding.")
        return .none
    }

    // MARK: - Current user

    func resolveCurrentUserRecordID(cloudKit: any CloudKitServiceProtocol) async -> CKRecord.ID? {
        do {
            let userRecordID = try await cloudKit.currentUserRecordID()
            logger.info("Current user record ID: \(userRecordID.recordName, privacy: .private)")
            return userRecordID
        } catch {
            logger.warning("Could not resolve current iCloud user record ID: \(error, privacy: .private)")
            return nil
        }
    }

    // MARK: - Private owner discovery

    func discoverPrivateOwnerCandidates(
        cloudKit: any CloudKitServiceProtocol,
        userRecordID: CKRecord.ID?
    ) async -> [DiscoveredFamilyCandidate] {
        do {
            let privateZones = try await cloudKit.fetchPrivateZones()
            logger.info("Found \(privateZones.count) private zones")
            let customZones = privateZones.filter { $0.zoneID.zoneName != "_defaultZone" && $0.zoneID.zoneName != "LootListZone" }

            var candidates: [DiscoveredFamilyCandidate] = []
            for zone in customZones {
                logger.info("Inspecting private custom zone: '\(zone.zoneID.zoneName, privacy: .private)'")
                let db = await MainActor.run { cloudKit.privateDatabase }
                var family: Family?

                let familyID = CKRecord.ID(recordName: zone.zoneID.zoneName, zoneID: zone.zoneID)
                do {
                    family = try await cloudKit.fetch(Family.self, id: familyID, using: db)
                    if let family {
                        logger.info("Direct point lookup found Family: '\(family.name, privacy: .private)'")
                    }
                } catch {
                    logger.debug("Direct point lookup for Family in zone '\(zone.zoneID.zoneName, privacy: .private)' did not hit: \(error, privacy: .private)")
                }

                if family == nil {
                    do {
                        let families: [Family] = try await cloudKit.query(Family.self, predicate: NSPredicate(value: true), in: zone.zoneID, using: db)
                        family = families.count == 1 ? families.first : nil
                        if families.count > 1 {
                            logger.warning("Rejecting ambiguous Family records in private zone '\(zone.zoneID.zoneName, privacy: .private)'")
                        }
                        logger.info("Query fallback returned \(families.count) Family records.")
                    } catch {
                        logger.error("Query fallback error for zone '\(zone.zoneID.zoneName, privacy: .private)': \(error, privacy: .private)")
                    }
                }

                if let foundFamily = family,
                   let userRecordID
                {
                    let zoneOwner = zone.zoneID.ownerName
                    let isZoneOwnedByUser = zoneOwner == userRecordID.recordName
                        || zoneOwner == CKCurrentUserDefaultName
                        || zoneOwner == "__defaultOwner__"
                        || zoneOwner == "_defaultOwner_"
                    let familyCreatorMatches = foundFamily.creatorUserRecordName == userRecordID.recordName
                        || foundFamily.createdBy.recordName == userRecordID.recordName
                    let isPlaceholderFamilyCreator = AppConstants.Security.legacyPlaceholderCreators
                        .contains(foundFamily.creatorUserRecordName ?? "")
                        || AppConstants.Security.legacyPlaceholderCreators.contains(foundFamily.createdBy.recordName)
                    let shouldConsiderFamily = familyCreatorMatches || isZoneOwnedByUser || (isPlaceholderFamilyCreator && isZoneOwnedByUser)
                    guard shouldConsiderFamily else {
                        logger.info(
                            """
                            Skipping family '\(foundFamily.name, privacy: .private)' — owner mismatch \
                            (family creator \(foundFamily.creatorUserRecordName ?? "nil", privacy: .private), \
                            zone owner \(zoneOwner, privacy: .private))
                            """
                        )
                        continue
                    }
                    do {
                        let familyRef = CKRecord.Reference(recordID: foundFamily.id, action: .none)
                        let profiles: [Profile] = try await cloudKit.query(
                            Profile.self,
                            predicate: NSPredicate(format: "family == %@", familyRef),
                            in: zone.zoneID,
                            using: db
                        )
                        let matchingProfiles = profiles.filter {
                            let creatorOK = $0.creatorUserRecordName == userRecordID.recordName
                                || $0.creatorUserRecordName == nil
                                || AppConstants.Security.legacyPlaceholderCreators.contains($0.creatorUserRecordName ?? "")
                            return $0.isActive
                                && $0.role == .guildMaster
                                && $0.family.recordID == foundFamily.id
                                && creatorOK
                                && $0.iCloudUserID.recordName == userRecordID.recordName
                        }
                        guard matchingProfiles.count == 1, let activeProfile = matchingProfiles.first else {
                            if matchingProfiles.count > 1 {
                                logger.warning("Rejecting ambiguous owner identity in family '\(foundFamily.name, privacy: .private)'")
                            }
                            continue
                        }
                        candidates.append(DiscoveredFamilyCandidate(family: foundFamily, profile: activeProfile, zoneID: zone.zoneID))
                    } catch {
                        logger.error("Profile query error for zone '\(zone.zoneID.zoneName, privacy: .private)': \(error, privacy: .private)")
                    }
                }
            }
            return candidates
        } catch {
            logger.error("Error fetching private zones: \(error, privacy: .private)")
            return []
        }
    }

    // MARK: - Shared hero discovery

    func discoverSharedHeroCandidates(
        cloudKit: any CloudKitServiceProtocol,
        userRecordID: CKRecord.ID?
    ) async -> [DiscoveredFamilyCandidate] {
        let sharedZones = await fetchSharedZonesWithBoundedRetry(cloudKit: cloudKit)

        logger.info("Final shared zones count: \(sharedZones.count)")

        var candidates: [DiscoveredFamilyCandidate] = []
        for zone in sharedZones {
            logger.info("Inspecting shared zone: '\(zone.zoneID.zoneName, privacy: .private)' (owner: '\(zone.zoneID.ownerName, privacy: .private)')")

            let activeProfiles = await activeSharedHeroProfiles(
                cloudKit: cloudKit,
                userRecordID: userRecordID,
                zoneID: zone.zoneID
            )
            if activeProfiles.count == 1,
               let activeHeroProfile = activeProfiles.first,
               let family = await sharedZoneFamily(cloudKit: cloudKit, zoneID: zone.zoneID),
               activeHeroProfile.family.recordID == family.id
            {
                candidates.append(DiscoveredFamilyCandidate(family: family, profile: activeHeroProfile, zoneID: zone.zoneID))
            }
        }
        return candidates
    }

    func fetchSharedZonesWithBoundedRetry(
        cloudKit: any CloudKitServiceProtocol
    ) async -> [CKRecordZone] {
        do {
            let sharedZones = try await cloudKit.fetchSharedZones()
            logger.info("Initial shared zones check: \(sharedZones.count) shared zones")

            if sharedZones.isEmpty {
                let remainingPulses = max(0, AppConstants.Sync.maxPulseAttempts - 1)
                if remainingPulses > 0 {
                    for attempt in 1 ... remainingPulses {
                        logger.info("Shared zone sync pulse attempt \(attempt)...")
                        do {
                            let retryZones = try await cloudKit.fetchSharedZones()
                            if !retryZones.isEmpty {
                                return retryZones
                            }
                        } catch {
                            logger.debug("Shared zone sync pulse attempt \(attempt) failed: \(error, privacy: .private)")
                        }
                    }
                }
            }

            return sharedZones
        } catch {
            logger.error("Error fetching shared zones: \(error, privacy: .private)")
            return []
        }
    }

    // MARK: - Shared-zone helpers

    /// Finds active Profile matching current iCloud user in shared zones for recovery.
    func activeSharedHeroProfiles(
        cloudKit: any CloudKitServiceProtocol,
        userRecordID: CKRecord.ID?,
        zoneID: CKRecordZone.ID
    ) async -> [Profile] {
        guard userRecordID != nil else { return [] }

        let sharedDB = await MainActor.run { cloudKit.sharedDatabase }

        let profiles: [Profile]
        do {
            profiles = try await cloudKit.query(
                Profile.self,
                predicate: NSPredicate(value: true),
                in: zoneID,
                using: sharedDB
            )
        } catch {
            Self.logger.error("Failed to query shared hero profiles in zone '\(zoneID.zoneName, privacy: .private)': \(error, privacy: .private)")
            return []
        }

        guard let userRecordName = userRecordID?.recordName else { return [] }

        var matches: [Profile] = []
        for profile in profiles where profile.isActive && profile.iCloudUserID.recordName == userRecordName {
            if let creatorUserRecordName = profile.creatorUserRecordName {
                guard creatorUserRecordName == userRecordName
                    || AppConstants.Security.legacyPlaceholderCreators.contains(creatorUserRecordName)
                else { continue }
                matches.append(profile)
                continue
            }

            let serverProfile: Profile
            do {
                serverProfile = try await cloudKit.fetch(
                    Profile.self,
                    id: profile.id,
                    using: sharedDB
                )
            } catch {
                Self.logger
                    .debug(
                        "Shared profile fetch failed for '\(profile.id.recordName, privacy: .private)' (expected for revoked/missing shares): \(error, privacy: .private)"
                    )
                continue
            }

            guard serverProfile.isActive,
                  serverProfile.iCloudUserID.recordName == userRecordName,
                  serverProfile.creatorUserRecordName == userRecordName
                  || AppConstants.Security.legacyPlaceholderCreators.contains(serverProfile.creatorUserRecordName ?? ""),
                  serverProfile.family.recordID == profile.family.recordID
            else { continue }

            matches.append(serverProfile)
        }
        return matches.count == 1 ? matches : []
    }

    /// The `Family` record in a shared zone: a direct point lookup on the
    /// zone-named record first, with a full-zone query as fallback when the
    /// point lookup misses. Returns nil when neither path resolves a family.
    func sharedZoneFamily(
        cloudKit: any CloudKitServiceProtocol,
        zoneID: CKRecordZone.ID
    ) async -> Family? {
        let familyID = CKRecord.ID(recordName: zoneID.zoneName, zoneID: zoneID)
        let sharedDB = await MainActor.run { cloudKit.sharedDatabase }
        do {
            return try await cloudKit.fetch(Family.self, id: familyID, using: sharedDB)
        } catch {
            Self.logger.debug("Point lookup for shared family in zone '\(zoneID.zoneName, privacy: .private)' missed: \(error, privacy: .private)")
        }

        do {
            let families = try await cloudKit.query(
                Family.self,
                predicate: NSPredicate(value: true),
                in: zoneID,
                using: sharedDB
            )
            return families.count == 1 ? families.first : nil
        } catch {
            Self.logger.error("Fallback query for shared family in zone '\(zoneID.zoneName, privacy: .private)' failed: \(error, privacy: .private)")
            return nil
        }
    }

    // MARK: - Zone reachability

    /// Probes family zone reachability with a timeout to verify zone existence.
    func isZoneReachable(
        cloudKit: any CloudKitServiceProtocol,
        familyRecordName: String,
        zoneID: CKRecordZone.ID
    ) async -> Bool {
        let rootRecordID = CKRecord.ID(recordName: familyRecordName, zoneID: zoneID)
        let deadline = Date().addingTimeInterval(max(0.1, AppConstants.Session.zoneCheckTimeoutSeconds))
        for _ in 0 ..< max(1, AppConstants.Session.restoreRetryBudget) {
            if Date() >= deadline {
                return false
            }
            do {
                _ = try await cloudKit.fetchShareParticipants(for: rootRecordID)
                return true
            } catch {
                continue
            }
        }
        return false
    }
}
