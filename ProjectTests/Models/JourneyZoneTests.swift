//
//  JourneyZoneTests.swift
//  LootListTests
//
//  Created by Ben Mackin on 8/22/26.
//

@testable import LootList
import Testing

@Suite("JourneyZone")
struct JourneyZoneTests {
    // MARK: - Zone Lookup

    @Test
    func `zone(forLevel:) returns correct zone at boundaries`() {
        #expect(JourneyZone.zone(forLevel: 1) == .startingMeadow)
        #expect(JourneyZone.zone(forLevel: 5) == .startingMeadow)
        #expect(JourneyZone.zone(forLevel: 6) == .denseForest)
        #expect(JourneyZone.zone(forLevel: 10) == .denseForest)
        #expect(JourneyZone.zone(forLevel: 11) == .mountainPass)
        #expect(JourneyZone.zone(forLevel: 15) == .mountainPass)
        #expect(JourneyZone.zone(forLevel: 16) == .dragonsReach)
        #expect(JourneyZone.zone(forLevel: 20) == .dragonsReach)
        #expect(JourneyZone.zone(forLevel: 21) == .eternalRealm)
        #expect(JourneyZone.zone(forLevel: 50) == .eternalRealm)
        #expect(JourneyZone.zone(forLevel: 100) == .eternalRealm)
    }

    @Test
    func `zone(forLevel:) handles edge cases`() {
        // Level 0 or negative should map to eternalRealm (falls through)
        // since no zone contains level 0
        let zoneForZero = JourneyZone.zone(forLevel: 0)
        #expect(zoneForZero == .eternalRealm)
    }

    // MARK: - Display Properties

    @Test
    func `all zones have non-empty display names`() {
        for zone in JourneyZone.allCases {
            #expect(!zone.displayName.isEmpty, "Zone \(zone) has empty displayName")
        }
    }

    @Test
    func `all zones have non-empty short names`() {
        for zone in JourneyZone.allCases {
            #expect(!zone.shortName.isEmpty, "Zone \(zone) has empty shortName")
        }
    }

    @Test
    func `all zones have non-empty flavor text`() {
        for zone in JourneyZone.allCases {
            #expect(!zone.flavorText.isEmpty, "Zone \(zone) has empty flavorText")
        }
    }

    @Test
    func `all zones have non-empty icon system names`() {
        for zone in JourneyZone.allCases {
            #expect(!zone.iconSystemName.isEmpty, "Zone \(zone) has empty iconSystemName")
        }
    }

    // MARK: - Level Ranges

    @Test
    func `caseIterable covers all 5 zones`() {
        #expect(JourneyZone.allCases.count == 5)
    }

    @Test
    func `level ranges for non-eternal zones cover exactly 5 levels each`() {
        #expect(JourneyZone.startingMeadow.levelRange.count == 5)
        #expect(JourneyZone.denseForest.levelRange.count == 5)
        #expect(JourneyZone.mountainPass.levelRange.count == 5)
        #expect(JourneyZone.dragonsReach.levelRange.count == 5)
    }

    @Test
    func `eternalRealm starts at level 21`() {
        #expect(JourneyZone.eternalRealm.startLevel == 21)
        #expect(JourneyZone.eternalRealm.levelRange.lowerBound == 21)
    }

    @Test
    func `non-eternal zones have contiguous non-overlapping level ranges`() {
        let finiteZones: [JourneyZone] = [.startingMeadow, .denseForest, .mountainPass, .dragonsReach]
        for index in 0 ..< (finiteZones.count - 1) {
            let currentUpper = finiteZones[index].levelRange.upperBound
            let nextLower = finiteZones[index + 1].levelRange.lowerBound
            #expect(nextLower == currentUpper + 1,
                    "\(finiteZones[index]) upper \(currentUpper) is not contiguous with \(finiteZones[index + 1]) lower \(nextLower)")
        }
    }

    // MARK: - Milestone Count

    @Test
    func `milestone counts match expected values`() {
        #expect(JourneyZone.startingMeadow.milestoneCount == 5)
        #expect(JourneyZone.denseForest.milestoneCount == 5)
        #expect(JourneyZone.mountainPass.milestoneCount == 5)
        #expect(JourneyZone.dragonsReach.milestoneCount == 5)
        #expect(JourneyZone.eternalRealm.milestoneCount == JourneyZone.eternalRealmDisplayCap)
    }

    // MARK: - Zone Palette

    @Test
    func `all zones produce a valid palette`() {
        for zone in JourneyZone.allCases {
            let palette = zone.palette
            // Just ensure the palette properties are accessible (non-crash)
            _ = palette.pathColor
            _ = palette.groundColor
            _ = palette.accentColor
            _ = palette.skyGradient
        }
    }
}
