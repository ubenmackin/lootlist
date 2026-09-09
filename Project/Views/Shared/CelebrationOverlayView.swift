//
//  CelebrationOverlayView.swift
//  LootList
//
//  Created by Ben Mackin on 8/10/26.
//

import SwiftUI

/// Compatibility forwarding view retained for legacy callers; canonical canvas lives in CelebrationOverlay.
struct CelebrationOverlayView: View {
    let isPresented: Bool

    var body: some View {
        CelebrationOverlay(isPresented: isPresented)
    }
}
