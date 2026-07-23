import Foundation

extension NumberFormatter {
    /// A shared formatter for displaying gold amounts with comma separators and exactly two decimal places.
    ///
    /// `NumberFormatter` is expensive to create; use this static instance instead of allocating per-call.
    static let goldFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}
