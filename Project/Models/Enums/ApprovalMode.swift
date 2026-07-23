import Foundation

enum ApprovalMode: String, Codable, CaseIterable, Sendable {
    case autoApprove

    case parentVerify

    var displayName: String {
        switch self {
        case .autoApprove: "Auto-Approve"
        case .parentVerify: "Parent Verifies"
        }
    }

    var iconSystemName: String {
        switch self {
        case .autoApprove: "checkmark.seal.fill"
        case .parentVerify: "eye.fill"
        }
    }
}
