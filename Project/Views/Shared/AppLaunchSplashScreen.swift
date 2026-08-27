//
//  AppLaunchSplashScreen.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

struct AppLaunchSplashScreen: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(DesignSystemConstants.Colors.accentBlue),
                    Color(DesignSystemConstants.Colors.accentBlue).opacity(0.75)
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
                                colors: [.gold, Color(DesignSystemConstants.Colors.pendingAmber)],
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

                    // The realm flavor line belongs to the immersive layer;
                    // keeping the default launch plain preserves it for when
                    // that layer is switched back on.
                    if FeatureFlags.rpgImmersive {
                        Text("Entering the Realm…")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.gold.opacity(0.85))
                    } else {
                        // Neutral branding for the default launch: says what
                        // the app does, no fantasy framing.
                        Text("Chores, allowance & savings")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }

                ProgressView()
                    .tint(.gold)
                    .scaleEffect(1.2)
                    .padding(.top, 12)
            }
        }
    }
}
