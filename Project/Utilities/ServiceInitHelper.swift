//
//  ServiceInitHelper.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import Foundation
import os

@MainActor
enum ServiceInitHelper {
    static func resolveCacheService(
        provided: (any CacheServicing)?,
        logger: Logger,
        serviceName: String
    ) -> any CacheServicing {
        if let provided {
            return provided
        } else {
            logger.warning("\(serviceName) initialized without cacheService; using fallback in-memory cache.")
            return CacheService.inMemoryFallback(logger: logger)
        }
    }

    static func resolveSyncCoordinator(
        provided: (any SyncEnqueuing)?,
        logger: Logger,
        serviceName: String
    ) -> any SyncEnqueuing {
        if let resolvedCoord: any SyncEnqueuing = provided ?? AppDependencies.shared?.syncCoordinator {
            return resolvedCoord
        } else {
            #if DEBUG
                if TestEnvironment.isRunningUnitOrUITests {
                    logger.warning("\(serviceName) initialized without syncCoordinator; using test Noop seam.")
                } else {
                    logger.error("\(serviceName) initialized without syncCoordinator and no shared coordinator; falling back to Noop seam.")
                }
                return NoopSyncEnqueuing()
            #else
                preconditionFailure("\(serviceName) requires a sync coordinator in production")
            #endif
        }
    }
}
