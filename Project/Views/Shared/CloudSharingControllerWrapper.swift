//
//  CloudSharingControllerWrapper.swift
//  LootList
//
//  Created by Ben Mackin on 8/11/26.
//

import CloudKit
import SwiftUI
import UIKit

/// SwiftUI presentation for the system iCloud share sheet. The Guild Master
/// resolves a `CKShare` for a chosen invite role, then presents this wrapper to
/// invite recipients.
///
/// We register the server-backed share on an `NSItemProvider` with explicit
/// `CKAllowedSharingOptions` and present via `UIActivityViewController`. This is
/// the only CloudKit share presentation that works on iOS 26: the legacy
/// `UICloudSharingController(share:container:)` fails to generate share links on
/// both device and Simulator (it never populates the collaboration panel's
/// option groups), while this path produces a working link and Messages invite.
struct CloudSharingControllerWrapper: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        // Private-share contract: participants are added only as explicit
        // `.readWrite` recipients. "Anyone with the link" is never offered, so
        // the share URL cannot become a public bearer credential for the
        // family zone; a read-only participant is never minted either.
        let allowedOptions = CKAllowedSharingOptions(
            allowedParticipantPermissionOptions: [.readWrite],
            allowedParticipantAccessOptions: [.specifiedRecipientsOnly]
        )
        let provider = NSItemProvider()
        provider.registerCKShare(share, container: container, allowedSharingOptions: allowedOptions)
        return UIActivityViewController(activityItems: [provider], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}

/// Identifiable presentation payload for `.sheet(item:)`: pairs the resolved
/// `CKShare` with the `CKContainer` that owns it.
struct CloudSharePresentation: Identifiable {
    let id = UUID()
    let share: CKShare
    let container: CKContainer
}
