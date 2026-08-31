//
//  CloudSharingControllerWrapper.swift
//  LootList
//
//  Created by Ben Mackin on 8/11/26.
//

import SwiftUI
import UIKit

/// Views never hold raw CloudKit types — the service seam vends an opaque
/// presentation that captures CKShare/CKContainer behind a provider factory.
/// Sharing UI necessarily touches CKShare, but that coupling stays in
/// CloudKitService+Sharing; this wrapper only consumes the factory.
struct CloudSharePresentation: Identifiable {
    let id: UUID
    let shareURL: URL?
    private let _makeProvider: () -> NSItemProvider

    init(id: UUID = UUID(), shareURL: URL?, makeProvider: @escaping () -> NSItemProvider) {
        self.id = id
        self.shareURL = shareURL
        self._makeProvider = makeProvider
    }

    func makeProvider() -> NSItemProvider {
        _makeProvider()
    }
}

struct CloudSharingControllerWrapper: UIViewControllerRepresentable {
    let presentation: CloudSharePresentation

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        let provider = presentation.makeProvider()
        return UIActivityViewController(activityItems: [provider], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
