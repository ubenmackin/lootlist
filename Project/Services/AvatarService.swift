import Foundation

enum AvatarPreset: String, CaseIterable, Sendable {

    case knight_v1
    case knight_v2
    case knight_v3

    case mage_v1
    case mage_v2
    case mage_v3

    case rogue_v1
    case rogue_v2
    case rogue_v3

    case guardian_v1
    case guardian_v2

    case healer_v1
    case healer_v2

    var avatarClass: AvatarClass {
        let prefix = rawValue.split(separator: "_").first.map(String.init) ?? rawValue
        return AvatarClass(rawValue: prefix) ?? .knight
    }

    var variationNumber: Int {
        guard let last = rawValue.split(separator: "_").last,
              last.hasPrefix("v"),
              let n = Int(last.dropFirst()) else { return 1 }
        return n
    }

    var id: String {
        String(format: "%@_%02d", avatarClass.presetPrefix, variationNumber)
    }

    var displayName: String {
        switch self {
        case .knight_v1:    return "Squire"
        case .knight_v2:    return "Knight Errant"
        case .knight_v3:    return "Paladin"
        case .mage_v1:     return "Apprentice"
        case .mage_v2:     return "Conjurer"
        case .mage_v3:     return "Archmage"
        case .rogue_v1:    return "Pickpocket"
        case .rogue_v2:    return "Scout"
        case .rogue_v3:    return "Shadowblade"
        case .guardian_v1: return "Sentinel"
        case .guardian_v2: return "Warden"
        case .healer_v1:   return "Acolyte"
        case .healer_v2:   return "Cleric"
        }
    }

    var iconSystemName: String {
        switch self {
        case .knight_v1:   return "shield"
        case .knight_v2:   return "shield.lefthalf.filled"
        case .knight_v3:   return "shield.checkered"
        case .mage_v1:     return "wand.and.stars.inverse"
        case .mage_v2:     return "wand.and.rays"
        case .mage_v3:     return "wand.and.stars"
        case .rogue_v1:    return "theatermasks.fill"
        case .rogue_v2:    return "theatermasks"
        case .rogue_v3:    return "eyebrow"
        case .guardian_v1: return "checkerboard.shield"
        case .guardian_v2: return "shield.lefthalf.filled"
        case .healer_v1:   return "cross.case.fill"
        case .healer_v2:   return "cross.case"
        }
    }

    var accessoryIconSystemName: String? {
        switch self {
        case .knight_v1:    return nil                    
        case .knight_v2:    return "helmets.fill"          
        case .knight_v3:    return "crown.fill"             
        case .mage_v1:      return nil
        case .mage_v2:      return "graduationcap.fill"     
        case .mage_v3:      return "moon.stars.fill"        
        case .rogue_v1:     return nil
        case .rogue_v2:     return "eyeglasses"             
        case .rogue_v3:     return "hood.fill"              
        case .guardian_v1:  return nil
        case .guardian_v2:  return "shield.lefthalf.filled"
        case .healer_v1:    return nil
        case .healer_v2:    return "cross.fill"             
        }
    }

    static func presets(for cls: AvatarClass) -> [AvatarPreset] {
        allCases.filter { $0.avatarClass == cls }
    }

    static func preset(forProfile profile: Profile) -> AvatarPreset {
        resolve(profile.avatarClass, id: profile.avatarPresetID)
            ?? presets(for: profile.avatarClass).first
            ?? .knight_v1
    }

    static func resolve(_ cls: AvatarClass, id: String) -> AvatarPreset? {

        if let hit = Self.presets(for: cls).first(where: { $0.id == id }) {
            return hit
        }

        let comps = id.split(separator: ".")
        if comps.count >= 2,
           let n = Int(comps.last?.dropFirst() ?? "") {
            let alt = "\(cls.rawValue)_v\(n)"
            if let hit = AvatarPreset(rawValue: alt),
               hit.avatarClass == cls {
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

    var avatarClass: AvatarClass { preset.avatarClass }
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
        case 5:   return "sparkles"
        case 10:  return "bolt.fill"
        case 15:  return "star.fill"
        case 20:  return "flame.fill"
        default:  return "sparkles"
        }
    }
}
