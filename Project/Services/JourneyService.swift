//
//  JourneyService.swift
//  LootList
//
//  Created by Ben Mackin on 8/22/26.
//

import Foundation

// MARK: - Journey Milestone

/// The visual state of a single level milestone on the journey map.
enum MilestoneState: Sendable, Equatable {
    /// The hero has already passed this level.
    case reached
    /// The hero is currently at this level.
    case current
    /// The hero has not yet reached this level.
    case future
}

/// A single milestone dot on the journey map path.
struct JourneyMilestone: Sendable, Equatable, Identifiable {
    let level: Int
    let zone: JourneyZone
    let state: MilestoneState
    let title: String
    let xpRequired: Int

    var id: Int {
        level
    }
}

// MARK: - Journey State

/// A snapshot of the hero's journey map, computed from their profile.
struct JourneyState: Sendable, Equatable {
    let currentLevel: Int
    let currentZone: JourneyZone
    let zonesUnlocked: [JourneyZone]
    let progress: Double
    let milestones: [JourneyMilestone]
}

// MARK: - Journey Service

/// Stateless utility that computes the journey map state from a `Profile`.
/// No persistence — everything is derived from the hero's current XP and level.
@MainActor
enum JourneyService {
    /// Maximum level rendered on the map. Levels beyond this show a trailing
    /// indicator but no individual milestone dots.
    static let maxDisplayLevel: Int = 30

    /// Builds the complete journey state for a hero profile.
    static func journeyState(for profile: Profile, xpService: XPService) -> JourneyState {
        let currentLevel = profile.level
        let currentZone = JourneyZone.zone(forLevel: currentLevel)
        let levelProgress = xpService.levelProgress(profile: profile)

        let zonesUnlocked = JourneyZone.allCases.filter { zone in
            zone.startLevel <= currentLevel
        }

        let milestones = buildMilestones(currentLevel: currentLevel)

        return JourneyState(
            currentLevel: currentLevel,
            currentZone: currentZone,
            zonesUnlocked: zonesUnlocked,
            progress: levelProgress.progress,
            milestones: milestones
        )
    }

    // MARK: - Private Helpers

    private static func buildMilestones(currentLevel: Int) -> [JourneyMilestone] {
        // Render levels 1 through maxDisplayLevel (or current level if higher).
        let displayCeil = max(maxDisplayLevel, min(currentLevel + 2, currentLevel + 5))

        return (1 ... displayCeil).map { level in
            let zone = JourneyZone.zone(forLevel: level)
            let state: MilestoneState = if level < currentLevel {
                .reached
            } else if level == currentLevel {
                .current
            } else {
                .future
            }
            return JourneyMilestone(
                level: level,
                zone: zone,
                state: state,
                title: XPService.title(forLevel: level),
                xpRequired: XPService.cumulativeXPForLevel(level)
            )
        }
    }

    /// Acknowledges that the hero has viewed up to `level` on the journey map,
    /// persisting the update to local cache and enqueueing CloudKit sync.
    static func acknowledgeJourneyLevel(
        _ level: Int,
        profile: Profile,
        appState: AppState?,
        cacheService: CacheService?,
        syncCoordinator: CKSyncEngineCoordinator?
    ) {
        guard level > profile.journeyMapLastSeenLevel else { return }
        var updated = profile
        updated.journeyMapLastSeenLevel = level

        cacheService?.upsertProfile(updated)

        if let current = appState?.currentProfile, current.id == updated.id {
            var reconciled = current
            reconciled.journeyMapLastSeenLevel = level
            appState?.currentProfile = reconciled
        }

        if let isOwner = appState?.isZoneOwner {
            syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        }
    }
}
