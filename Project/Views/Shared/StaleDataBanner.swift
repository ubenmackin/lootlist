//
//  StaleDataBanner.swift
//  LootList
//
//  Created by Ben Mackin on 8/30/26.
//

import SwiftUI

// WHY: Freshness watermarks are the sole authority for cache scope; stale non-empty
// cache must re-validate via CloudKit, so the banner reflects scope-aware
// isCacheAuthoritative rather than row count.
struct StaleDataBanner: View {
    @Environment(AppState.self) private var appState

    private let family: String?
    private let type: CachedRecordType?
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

    // WHY: Freshness-only authority — stale cache even with rows must be
    // treated as non-authoritative and re-validated via CloudKit.
    private var isStale: Bool {
        guard let family, let type, let count else { return true }
        // WHY: Observe watermark version so body recomputes after markCacheFresh without Query count change.
        _ = appState.cacheService?.freshnessVersion
        return !(appState.cacheService?.isCacheAuthoritative(familyRecordName: family, type: type, scope: appState.activeDatabaseScope, cachedCount: count) ?? false)
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

extension CacheService {
    /// Returns true when the local cache has rows for `type` but no freshness
    /// watermark for `family` — stale data that must be re-validated via CloudKit.
    func isStale(for family: String, type: CachedRecordType, cachedCount: Int) -> Bool {
        _ = freshnessVersion
        guard !family.isEmpty, cachedCount > 0 else { return false }
        return !isCacheFresh(familyRecordName: family, type: type)
    }
}
