//
//  FatalCacheErrorView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

struct FatalCacheErrorView: View {
    let message: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.14, green: 0.04, blue: 0.04),
                    Color(red: 0.22, green: 0.06, blue: 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.red, .orange],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: .red.opacity(0.4), radius: 12, x: 0, y: 4)

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
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
                }

                ScrollView {
                    Text(message)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.black.opacity(0.35))
                        )
                        .padding(.horizontal, 24)
                }
                .frame(maxHeight: 180)

                Button {
                    // The app cannot recover from a cache-init failure in-process.
                    // Offer a relaunch affordance; terminating is the only way back
                    // to a clean schema state.
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
                                        colors: [.red, .orange],
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
