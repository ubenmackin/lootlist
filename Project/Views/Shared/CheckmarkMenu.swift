//
//  CheckmarkMenu.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import SwiftUI

/// Toolbar menu presenting a mutually-exclusive option set with checkmark selection.
struct CheckmarkMenu<Option: Identifiable & Equatable>: View {
    let systemImage: String
    let options: [Option]
    let selected: Option?
    let onSelect: (Option) -> Void
    let title: (Option) -> String

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    onSelect(option)
                } label: {
                    Label(title(option), systemImage: "checkmark")
                        .opacity(selected == option ? 1 : 0)
                }
            }
        } label: {
            Image(systemName: systemImage)
        }
    }
}
