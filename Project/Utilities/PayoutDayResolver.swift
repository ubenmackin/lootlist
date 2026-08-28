//
//  PayoutDayResolver.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import Foundation

enum PayoutDayResolver {
    static func resolved(for profile: ProfileCache?, family: FamilyCache?) -> PayoutDay {
        profile?.payoutDayEnum ?? family?.payoutDayEnum ?? .sunday
    }

    static func resolved(for profile: Profile?, family: Family?) -> PayoutDay {
        profile?.payoutDay ?? family?.payoutDay ?? .sunday
    }

    static func resolved(for profile: ProfileCache?, family: Family?) -> PayoutDay {
        profile?.payoutDayEnum ?? family?.payoutDay ?? .sunday
    }

    static func resolved(for profile: Profile?, family: FamilyCache?) -> PayoutDay {
        profile?.payoutDay ?? family?.payoutDayEnum ?? .sunday
    }
}
