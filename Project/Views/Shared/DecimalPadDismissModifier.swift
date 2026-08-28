//
//  DecimalPadDismissModifier.swift
//  LootList
//
//  Created by Ben Mackin on 8/25/26.
//

import SwiftUI

/// Keyboard toolbar that dismisses a decimalPad field by resigning a FocusState binding.
struct FocusDecimalPadDismissModifier: ViewModifier {
    var isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFocused.wrappedValue = false }
                    .font(.body.weight(.semibold))
            }
        }
    }
}

extension View {
    /// Adds a keyboard Done button that resigns the given `FocusState` binding.
    func decimalPadDoneToolbar(isFocused: FocusState<Bool>.Binding) -> some View {
        modifier(FocusDecimalPadDismissModifier(isFocused: isFocused))
    }
}
