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
        // WHY explicit-only: callers inject the owned coordinator; no locator fallback so init order never matters.
        if let provided {
            return provided
        } else {
            #if DEBUG
                if TestEnvironment.isRunningUnitOrUITests {
                    logger.warning("\(serviceName) initialized without syncCoordinator; using test Noop seam.")
                    return NoopSyncEnqueuing()
                }
                // WHY trap-only-DEBUG: mis-wiring surfaces in development, Release stays launchable.
                preconditionFailure("\(serviceName) requires a sync coordinator")
            #else
                // WHY Noop-plus-fault: Release stays launchable while diagnostics capture mis-wiring.
                logger.fault("\(serviceName) initialized without syncCoordinator; using Noop seam.")
                return NoopSyncEnqueuing()
            #endif
        }
    }

    /// WHY explicit-only: import flow needs the same DEBUG-trap/Release-Noop contract without locator reach-in.
    static func resolveSyncCoordinating(
        provided: (any SyncEnqueuing & SyncCoordinating)?,
        logger: Logger,
        serviceName: String
    ) -> any SyncEnqueuing & SyncCoordinating {
        // WHY explicit-only: callers inject the owned coordinator; no locator fallback so init order never matters.
        if let provided {
            return provided
        } else {
            #if DEBUG
                if TestEnvironment.isRunningUnitOrUITests {
                    logger.warning("\(serviceName) initialized without syncCoordinator; using test Noop seam.")
                    return NoopSyncEnqueuing()
                }
                // WHY trap-only-DEBUG: mis-wiring surfaces in development, Release stays launchable.
                preconditionFailure("\(serviceName) requires a sync coordinator")
            #else
                // WHY Noop-plus-fault: Release stays launchable while diagnostics capture mis-wiring.
                logger.fault("\(serviceName) initialized without syncCoordinator; using Noop seam.")
                return NoopSyncEnqueuing()
            #endif
        }
    }
}
