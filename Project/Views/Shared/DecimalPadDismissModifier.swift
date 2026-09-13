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
    var amountText: Binding<String>?

    /// WHY locale key: the device separator varies (comma vs period), so the button mirrors it.
    private var decimalSeparator: String {
        Locale.current.decimalSeparator ?? "."
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if isFocused.wrappedValue {
                    HStack {
                        if amountText != nil {
                            Button(decimalSeparator) {
                                insertSeparator()
                            }
                            .font(.body.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .accessibilityLabel("Decimal separator")
                            .accessibilityIdentifier("decimalPad.separatorButton")
                        }
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

    /// WHY grouping allows decimal: 1,234 plus separator stays typeable on every device.
    private func insertSeparator() {
        guard let amountText else { return }
        let current = amountText.wrappedValue
        if current.contains(".") && current.contains(",") {
            return
        }
        if let separator = current.first(where: { $0 == "." || $0 == "," }) {
            guard CurrencyFormatter.isGrouping(text: current, separator: separator) else { return }
        }
        // WHY zero prefix: a bare separator never parses, so seed a valid fractional prefix.
        let candidate = current.isEmpty ? "0" + decimalSeparator : current + decimalSeparator
        // WHY trailing probe: grouping plus separator needs a fractional digit to parse.
        guard CurrencyFormatter.pennies(from: candidate) != nil || CurrencyFormatter.pennies(from: candidate + "0") != nil else { return }
        amountText.wrappedValue = candidate
    }
}

extension View {
    /// Adds a keyboard Done button that resigns the given `FocusState` binding.
    func decimalPadDoneToolbar(
        isFocused: FocusState<Bool>.Binding,
        amountText: Binding<String>? = nil
    ) -> some View {
        modifier(FocusDecimalPadDismissModifier(isFocused: isFocused, amountText: amountText))
    }
}
