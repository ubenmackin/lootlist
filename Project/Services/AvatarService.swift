import Foundation

enum AvatarPreset: String, CaseIterable, Sendable {
    case knightV1 = "knight_v1"
    case knightV2 = "knight_v2"
    case knightV3 = "knight_v3"
    case knightV4 = "knight_v4"

    case mageV1 = "mage_v1"
    case mageV2 = "mage_v2"
    case mageV3 = "mage_v3"
    case mageV4 = "mage_v4"

    case rogueV1 = "rogue_v1"
    case rogueV2 = "rogue_v2"
    case rogueV3 = "rogue_v3"
    case rogueV4 = "rogue_v4"

    case guardianV1 = "guardian_v1"
    case guardianV2 = "guardian_v2"
    case guardianV3 = "guardian_v3"
    case guardianV4 = "guardian_v4"

    case healerV1 = "healer_v1"
    case healerV2 = "healer_v2"
    case healerV3 = "healer_v3"
    case healerV4 = "healer_v4"

    var avatarClass: AvatarClass {
        let prefix = rawValue.split(separator: "_").first.map(String.init) ?? rawValue
        return AvatarClass(rawValue: prefix) ?? .knight
    }

    var variationNumber: Int {
        guard let last = rawValue.split(separator: "_").last,
              last.hasPrefix("v"),
              let variationIndex = Int(last.dropFirst()) else { return 1 }
        return variationIndex
    }

    var id: String {
        String(format: "%@_%02d", avatarClass.presetPrefix, variationNumber)
    }

    var assetName: String {
        "avatar_\(id)"
    }

    var displayName: String {
        switch self {
        case .knightV1: "Sir Valorous (M)"
        case .knightV2: "Sir Galahad (M)"
        case .knightV3: "Lady Clara (F)"
        case .knightV4: "Lady Joan (F)"
        case .mageV1: "Archmage Ignis (M)"
        case .mageV2: "Sorcerer Zephyr (M)"
        case .mageV3: "Enchantress Astra (F)"
        case .mageV4: "Pyromancer Ember (F)"
        case .rogueV1: "Shadowblade (M)"
        case .rogueV2: "Scout Fox (M)"
        case .rogueV3: "Nightstalker (F)"
        case .rogueV4: "Bandit Ruby (F)"
        case .guardianV1: "Ironclad Aegis (M)"
        case .guardianV2: "Sentinel Titan (M)"
        case .guardianV3: "Defender Freya (F)"
        case .guardianV4: "Warden Briar (F)"
        case .healerV1: "High Priest Sol (M)"
        case .healerV2: "Monk Chen (M)"
        case .healerV3: "Cleric Lumina (F)"
        case .healerV4: "Druid Willow (F)"
        }
    }

    var iconSystemName: String {
        switch self {
        case .knightV1, .knightV2: "shield.fill"
        case .knightV3, .knightV4: "shield.checkered"
        case .mageV1, .mageV2: "wand.and.stars.inverse"
        case .mageV3, .mageV4: "wand.and.stars"
        case .rogueV1, .rogueV2: "theatermasks.fill"
        case .rogueV3, .rogueV4: "theatermasks"
        case .guardianV1, .guardianV2: "checkerboard.shield"
        case .guardianV3, .guardianV4: "shield.lefthalf.filled"
        case .healerV1, .healerV2: "cross.case.fill"
        case .healerV3, .healerV4: "cross.case"
        }
    }

    var accessoryIconSystemName: String? {
        switch self {
        case .knightV1, .knightV2: nil
        case .knightV3, .knightV4: "crown.fill"
        case .mageV1, .mageV2: nil
        case .mageV3, .mageV4: "moon.stars.fill"
        case .rogueV1, .rogueV2: nil
        case .rogueV3, .rogueV4: "hood.fill"
        case .guardianV1, .guardianV2: nil
        case .guardianV3, .guardianV4: "shield.lefthalf.filled"
        case .healerV1, .healerV2: nil
        case .healerV3, .healerV4: "cross.fill"
        }
    }

    static func presets(for cls: AvatarClass) -> [AvatarPreset] {
        allCases.filter { $0.avatarClass == cls }
    }

    static func preset(forProfile profile: Profile) -> AvatarPreset {
        resolve(profile.avatarClass, id: profile.avatarPresetID)
            ?? presets(for: profile.avatarClass).first
            ?? .knightV1
    }

    static func resolve(_ cls: AvatarClass, id: String) -> AvatarPreset? {
        if let hit = presets(for: cls).first(where: { $0.id == id }) {
            return hit
        }

        let comps = id.split(separator: ".")
        if comps.count >= 2,
           let variationIndex = Int(comps.last?.dropFirst() ?? "")
        {
            let alt = "\(cls.rawValue)_v\(variationIndex)"
            if let hit = AvatarPreset(rawValue: alt),
               hit.avatarClass == cls
            {
                return hit
            }
        }
        return nil
    }
}

struct AvatarRenderSpec: Equatable, Sendable {
    let preset: AvatarPreset

    let displayName: String

    let levelTitle: String

    let equippedAccessory: String?

    var avatarClass: AvatarClass {
        preset.avatarClass
    }
}

@MainActor
@Observable
final class AvatarService {
    private let xp: XPService

    init(xp: XPService) {
        self.xp = xp
    }

    static func presets(for cls: AvatarClass) -> [AvatarPreset] {
        AvatarPreset.presets(for: cls)
    }

    static func defaultPresetID(for cls: AvatarClass) -> String {
        cls.presetPrefix + "_01"
    }

    func renderSpec(for profile: Profile) -> AvatarRenderSpec {
        let preset = AvatarPreset.preset(forProfile: profile)
        let title = XPService.title(forLevel: profile.level)
        let unlocked = xp.unlockedAccessories(profile: profile)
        let equipped = unlocked.last
        return AvatarRenderSpec(
            preset: preset,
            displayName: profile.displayName,
            levelTitle: title,
            equippedAccessory: equipped
        )
    }
}

extension AvatarService {
    static func accessoryGlyph(for accessoryID: String) -> String? {
        guard accessoryID.hasPrefix("accessory.level.") else { return nil }
        let suffix = accessoryID
            .replacingOccurrences(of: "accessory.level.", with: "")
        guard let gate = Int(suffix) else { return nil }
        switch gate {
        case 5: return "sparkles"
        case 10: return "bolt.fill"
        case 15: return "star.fill"
        case 20: return "flame.fill"
        default: return "sparkles"
        }
    }
}
