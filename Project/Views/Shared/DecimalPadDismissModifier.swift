//
//  DecimalPadDismissModifier.swift
//  LootList
//
//  Created by Ben Mackin on 8/25/26.
//

import SwiftUI

/// Keyboard toolbar that dismisses a decimalPad field by resigning a FocusState binding.
/// WHY: Uses safeAreaInset instead of ToolbarItemGroup(placement: .keyboard)/inputAccessoryView to avoid non-finite frame faults (Invalid frame dimension).
struct FocusDecimalPadDismissModifier: ViewModifier {
    var isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if isFocused.wrappedValue {
                    HStack {
                        Spacer()
                        Button("Done") {
                            isFocused.wrappedValue = false
                        }
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .background(.bar)
                }
            }
            .scrollDismissesKeyboard(.interactively)
    }
}

extension View {
    /// Adds a keyboard Done button that resigns the given `FocusState` binding.
    func decimalPadDoneToolbar(isFocused: FocusState<Bool>.Binding) -> some View {
        modifier(FocusDecimalPadDismissModifier(isFocused: isFocused))
    }
}
