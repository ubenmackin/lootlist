//
//  SectionHeader.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// Card section header with an optional trailing slot (count label, "View All"
/// link, etc.).
struct SectionHeader<Trailing: View>: View {
    let title: String

    var identifier: String?

    @ViewBuilder let trailing: Trailing

    init(_ title: String, identifier: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.identifier = identifier
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            trailing
        }
        .accessibilityIdentifierIfSet(identifier)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, identifier: String? = nil) {
        self.init(title, identifier: identifier) { EmptyView() }
    }
}

extension View {
    /// Applies an accessibility identifier only when the caller supplied one,
    /// keeping optional identifier plumbing terse across reusable components.
    @ViewBuilder
    func accessibilityIdentifierIfSet(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
