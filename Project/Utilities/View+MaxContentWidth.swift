//
//  View+MaxContentWidth.swift
//  LootList
//
//  Created by Ben Mackin on 9/01/26.
//

import SwiftUI

extension View {
    /// Constrains reader width on iPad while staying full-width on iPhone.
    /// WHY: 1040 caps line length on 11" and 50/50; single frame with center alignment avoids redundant double-frame ambiguity on 50/50 split.
    func maxContentWidth() -> some View {
        frame(maxWidth: DesignSystemConstants.Layout.maxContentWidth, alignment: .center)
    }

    /// Narrow cap for banners and empty states so they do not stretch full-width on iPad.
    /// WHY: single frame with center alignment avoids redundant double-frame ambiguity on 50/50 split.
    func maxBannerWidth() -> some View {
        frame(maxWidth: DesignSystemConstants.Layout.maxBannerWidth, alignment: .center)
    }
}

// MARK: - Adaptive 1040-constrained split (DRY ViewThatFits)

/// Centralizes the 1040-constrained ViewThatFits fallback used across dashboard screens.
/// WHY: PayoutHistoryView, FamilyDashboardView, and ChildHub layout previously copy-pasted
/// ViewThatFits(in:.horizontal) { NavigationSplitView } else { compact } 3×. Single source
/// below keeps the 1040 cap and 50/50 collapse in sync; compact fallback renders when the
/// regular split no longer fits.
@MainActor
struct ViewThatFitsSplit<RegularContent: View, CompactContent: View>: View {
    @ViewBuilder let regularContent: RegularContent
    @ViewBuilder let compactContent: CompactContent

    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularContent
            compactContent
        }
    }
}
