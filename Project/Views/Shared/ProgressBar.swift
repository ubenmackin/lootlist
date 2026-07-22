import SwiftUI

struct ProgressBar: View {

    let value: Double

    let maximum: Double

    let label: String?

    var tint: Color = .blue

    var height: CGFloat = 8

    @State private var appeared: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            track
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label ?? "Progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
        .onAppear { animateFill() }
        .onChange(of: value)    { _, _ in animateFill() }
        .onChange(of: maximum)  { _, _ in animateFill() }
    }

    private var track: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackFill)
                    .frame(width: proxy.size.width, height: height)

                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * currentFraction, height: height)
                    .shadow(color: tint.opacity(0.45), radius: 4, y: 1)
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }

    private var trackFill: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.secondary.opacity(0.18),
                Color.secondary.opacity(0.10)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var fraction: Double {
        guard maximum > 0 else { return 0 }
        return min(max(value / maximum, 0.0), 1.0)
    }

    private var currentFraction: Double {
        appeared ? fraction : 0
    }

    private func animateFill() {
        withAnimation(.easeInOut(duration: 0.45)) {
            appeared = true
        }
    }
}
