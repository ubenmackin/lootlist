//
//  DismissalKeys.swift
//  LootList
//
//  Created by Ben Mackin on 9/5/26.
//

import Foundation
import SwiftUI

extension String? {
    /// Trims whitespace and maps empty to nil so fail-closed predicates never match `""`.
    /// WHY single source: the empty-to-nil sanitize was triplicated across views and dismissal scoping; one helper keeps empty-scope semantics identical.
    var sanitizedNilIfEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Centralized UserDefaults keys for device-local dismissal gates.
/// WHY central: literals for hasSeenNotificationPrime etc were duplicated 9× across VMs and Views; single source prevents drift and scopes correctly.
enum DismissalKeys {
    static let hasSeenNotificationPrime = "hasSeenNotificationPrime"
    static let hasDismissedHeroChecklist = "hasDismissedHeroChecklist"
    static let hasDismissedBucketBanner = "hasDismissedBucketBanner"
    static let hasDismissedQuestHintCard = "hasDismissedQuestHintCard"

    static func scoped(_ base: String, familyRecordName: String?, profileRecordName: String?) -> String {
        guard let family = familyRecordName.sanitizedNilIfEmpty,
              let profile = profileRecordName.sanitizedNilIfEmpty
        else {
            return base
        }
        return "\(base)_\(family)_\(profile)"
    }

    /// Single read path for dismissal gates — scoped key when identity resolves, legacy base key otherwise.
    /// WHY pure read: view bodies must not write during render, so legacy promotion lives in migrate(base:family:profile:) instead.
    static func effectiveBool(
        _ base: String,
        familyRecordName: String?,
        profileRecordName: String?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let key = scoped(base, familyRecordName: familyRecordName, profileRecordName: profileRecordName)
        guard key != base else {
            return DismissalStore.bool(forKey: key, defaults: defaults)
        }
        if DismissalStore.bool(forKey: key, defaults: defaults) {
            return true
        }
        return DismissalStore.bool(forKey: base, defaults: defaults)
    }

    /// One-time legacy promotion of the bare base key to the scoped key.
    /// WHY explicit: call from .task or ViewModel init so the write never runs inside a view body.
    static func migrate(
        _ base: String,
        familyRecordName: String?,
        profileRecordName: String?,
        defaults: UserDefaults = .standard
    ) {
        let key = scoped(base, familyRecordName: familyRecordName, profileRecordName: profileRecordName)
        guard key != base else { return }
        guard DismissalStore.bool(forKey: base, defaults: defaults) else { return }
        guard !DismissalStore.bool(forKey: key, defaults: defaults) else {
            DismissalStore.remove(base, defaults: defaults)
            return
        }
        DismissalStore.set(true, forKey: key, defaults: defaults)
        DismissalStore.remove(base, defaults: defaults)
    }

    /// Single binding path so Views share one computation instead of triplicating get/set wrappers.
    static func scopedBinding(
        _ base: String,
        familyRecordName: String?,
        profileRecordName: String?,
        defaults: UserDefaults = .standard
    ) -> Binding<Bool> {
        let box = DefaultsBox(defaults: defaults)
        return Binding(
            get: { effectiveBool(base, familyRecordName: familyRecordName, profileRecordName: profileRecordName, defaults: box.defaults) },
            set: { newValue in
                DismissalStore.set(
                    newValue,
                    forKey: scoped(base, familyRecordName: familyRecordName, profileRecordName: profileRecordName),
                    defaults: box.defaults
                )
            }
        )
    }
}

/// Sendable holder for a UserDefaults suite.
/// WHY unchecked: UserDefaults is thread-safe, so sharing one suite across the @Sendable Binding closures is race-safe.
private struct DefaultsBox: @unchecked Sendable {
    let defaults: UserDefaults
}

/// Service-owned device-local store for dismissal gates.
/// WHY service-owned: Views/ViewModels never touch UserDefaults directly; all dismissal reads/writes ride this store.
/// WHY injected defaults: the suite defaults to `.standard` so call sites stay unchanged, while tests pass an
/// ephemeral suite for hermetic dismissal assertions.
enum DismissalStore {
    static func bool(forKey key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func set(_ value: Bool, forKey key: String, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: key)
    }

    static func remove(_ key: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    static func markSeen(_ base: String, familyRecordName: String?, profileRecordName: String?, defaults: UserDefaults = .standard) {
        set(true, forKey: DismissalKeys.scoped(base, familyRecordName: familyRecordName, profileRecordName: profileRecordName), defaults: defaults)
    }
}

/// Fail-closed profile-row resolver shared by hero surfaces.
/// WHY shared: the targeted-row-or-session-match lookup was triplicated; single helper keeps empty-scope semantics identical.
enum ProfileRowResolver {
    static func resolve(rows: [ProfileCache], targetRecordName: String?) -> ProfileCache? {
        guard let target = targetRecordName.sanitizedNilIfEmpty else {
            return nil
        }
        return rows.first(where: { $0.recordName == target })
    }
}
