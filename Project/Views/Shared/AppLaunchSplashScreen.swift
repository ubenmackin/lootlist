import SwiftUI

struct AppLaunchSplashScreen: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.08, blue: 0.14),
                    Color(red: 0.14, green: 0.10, blue: 0.22)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.gold.opacity(0.35), Color.clear],
                                center: .center,
                                startRadius: 10,
                                endRadius: 70
                            )
                        )
                        .frame(width: 120, height: 120)

                    Image(systemName: "shield.fill")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.gold, .orange],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .shadow(color: .gold.opacity(0.5), radius: 12, x: 0, y: 4)
                }

                VStack(spacing: 6) {
                    Text("LootList")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Entering the Realm…")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.gold.opacity(0.85))
                }

                ProgressView()
                    .tint(.gold)
                    .scaleEffect(1.2)
                    .padding(.top, 12)
            }
        }
    }
}
