//
//  FatalCacheErrorView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

struct FatalCacheErrorView: View {
    var message: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(DesignSystemConstants.Colors.dangerRed),
                    Color(DesignSystemConstants.Colors.dangerRed).opacity(0.75)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Structural scrim: darkens the danger-token gradient so white copy keeps contrast in both modes.
            .overlay(Color.black.opacity(0.25))
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(DesignSystemConstants.Colors.dangerRed),
                                Color(DesignSystemConstants.Colors.pendingAmber)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Color(DesignSystemConstants.Colors.dangerRed).opacity(0.4), radius: 12, x: 0, y: 4)

                VStack(spacing: 8) {
                    Text("Cache Initialization Failed")
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)

                    Text(
                        "LootList could not start because its local data cache could not be opened. "
                            + "This is usually caused by a data schema change. Please relaunch the app; "
                            + "if the problem persists, reinstalling LootList will reset the cache."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                }

                #if DEBUG
                    if let message, !message.isEmpty {
                        ScrollView {
                            Text(message)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    // Structural scrim backing the mono text for legibility on the gradient.
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.black.opacity(0.35))
                                )
                                .padding(.horizontal, 24)
                        }
                        .frame(maxHeight: 180)
                    }
                #endif

                Button {
                    // Offer a relaunch affordance; terminating is the only way back
                    exit(1)
                } label: {
                    Label("Relaunch", systemImage: "arrow.clockwise")
                        .font(.headline)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(DesignSystemConstants.Colors.dangerRed),
                                            Color(DesignSystemConstants.Colors.pendingAmber)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                        .foregroundStyle(.white)
                }
            }
            .padding()
        }
    }
}
