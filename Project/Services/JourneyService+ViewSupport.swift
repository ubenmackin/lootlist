//
//  JourneyService+ViewSupport.swift
//  LootList
//
//  Created by Ben Mackin on 9/9/26.
//

import Foundation

/// WHY service owns enqueue: Views pass cache rows only so the engine handle never crosses into the View layer.
extension JourneyService {
    /// WHY shared container: the service resolves its own enqueue seam so Views never hold the coordinator.
    static func acknowledgeJourneyLevelFromView(
        _ level: Int,
        profileCache: ProfileCache,
        appState: AppState?
    ) async {
        guard let appState else { return }
        let cacheService = appState.cacheService
        let syncCoordinator: CKSyncEngineCoordinator? = AppDependencies.shared?.syncCoordinator
        await acknowledgeJourneyLevel(
            level,
            profileCache: profileCache,
            appState: appState,
            cacheService: cacheService,
            syncCoordinator: syncCoordinator
        )
    }
}
