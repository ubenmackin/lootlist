//
//  CloudSharingControllerWrapper.swift
//  LootList
//
//  Created by Ben Mackin on 8/11/26.
//

import CloudKit
import SwiftUI
import UIKit

struct CloudSharingControllerWrapper: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeUIViewController(context _: Context) -> UIActivityViewController {
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

struct CloudSharePresentation: Identifiable {
    let id = UUID()
    let share: CKShare
    let container: CKContainer

    var shareURL: URL? {
        share.url
    }
}
