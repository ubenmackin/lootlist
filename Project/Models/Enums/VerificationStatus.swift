import Foundation

enum VerificationStatus: String, Sendable, CaseIterable, Codable {

    case autoApproved

    case pending

    case verified

    case rejected

    var displayName: String {
        switch self {
        case .autoApproved: "Auto-Approved"
        case .pending:      "Pending"
        case .verified:     "Verified"
        case .rejected:     "Rejected"
        }
    }

    var iconSystemName: String {
        switch self {
        case .autoApproved: "checkmark.seal.fill"
        case .pending:      "hourglass"
        case .verified:     "checkmark.seal.fill"
        case .rejected:     "xmark.octagon.fill"
        }
    }
}
