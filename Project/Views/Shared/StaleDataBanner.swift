//
//  StaleDataBanner.swift
//  LootList
//
//  Created by Ben Mackin on 8/30/26.
//

import SwiftUI

/// Banner that indicates when local cached data may be stale based on freshness watermarks.
/// WHY: after a server-wins conflict discards an optimistic mutation, the cache is marked stale so this banner appears until the next foreground sync re-validates.
struct StaleDataBanner: View {
    @Environment(AppState.self) private var appState

    private let family: String?
    private let type: CachedRecordType?
    // WHY: count retained for ABI — scope-aware initializer captures cached row count but
    // staleness gates on authoritative watermark; extension isStale(for:cachedCount:) handles empty-cache case.
    private let count: Int?
    private let isSyncing: Bool

    /// Legacy initializer — always renders the banner. Caller controls
    /// visibility via an external `isStale` predicate.
    init(isSyncing: Bool = false) {
        self.family = nil
        self.type = nil
        self.count = nil
        self.isSyncing = isSyncing
    }

    /// Scope-aware initializer — banner renders only when the cached count
    /// for `family`/`type`/`scope` is stale.
    init(family: String, type: CachedRecordType, count: Int, isSyncing: Bool = false) {
        self.family = family
        self.type = type
        self.count = count
        self.isSyncing = isSyncing
    }

    private var isStale: Bool {
        guard let family, let type else { return true }
        // WHY: Observe watermark version so view recomputes when cache freshness changes; View stays CloudKit-free by delegating scope-aware check to CacheService.
        _ = appState.cacheService?.freshnessVersion
        return appState.cacheService?.isStaleWithoutScope(for: family, type: type, cachedCount: count ?? 0) ?? true
    }

    var body: some View {
        if isStale {
            HStack(spacing: 8) {
                if isSyncing {
                    ProgressView()
                        .tint(Color(DesignSystemConstants.Colors.pendingAmber))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                        .accessibilityHidden(true)
                }
                Text("Data may be stale — pull to refresh")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                    .strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.35), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Data may be stale — pull to refresh")
            .accessibilityIdentifier("staleDataBanner")
        }
    }
}
