//
//  AvatarCardView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

struct AvatarCardView: View {
    let model: AvatarCardModel

    var body: some View {
        ZStack(alignment: .top) {
            background
            content
                .padding(.bottom, 24)
                .padding(.horizontal, 20)
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.modal, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.modal, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(DesignSystemConstants.Colors.accentBlue).opacity(0.45),
                Color(DesignSystemConstants.Colors.accentBlue).opacity(0.35),
                Color(DesignSystemConstants.Colors.accentBlue).opacity(0.55)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            RadialGradient(
                colors: [Color.gold.opacity(0.25), .clear],
                center: .center,
                startRadius: 0, endRadius: 0.75
            )
        )
    }

    private var content: some View {
        VStack(spacing: 16) {
            avatarSymbol
            identityBlock
            levelBadge
            xpProgressBar
            if !model.accessories.isEmpty {
                accessoryStrip
            }
        }
        .padding(.top, 20)
        .frame(maxWidth: .infinity)
    }

    private var avatarSymbol: some View {
        ZStack {
            if let customData = model.customAvatarImageData, let uiImage = UIImage(data: customData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: DesignSystemConstants.AvatarSize.large, height: DesignSystemConstants.AvatarSize.large)
                    .clipShape(Circle())
                    .overlay(
                        Circle().strokeBorder(Color.gold.opacity(0.7), lineWidth: 2.5)
                    )
            } else if let emoji = model.avatarEmoji, !emoji.isEmpty {
                Circle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: DesignSystemConstants.AvatarSize.large, height: DesignSystemConstants.AvatarSize.large)
                    .overlay(
                        Circle().strokeBorder(Color.gold.opacity(0.7), lineWidth: 2.5)
                    )
                Text(emoji)
                    .font(.system(size: 56))
            } else {
                Circle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: DesignSystemConstants.AvatarSize.large, height: DesignSystemConstants.AvatarSize.large)
                    .overlay(
                        Circle().strokeBorder(Color.gold.opacity(0.7), lineWidth: 2.5)
                    )
                Image(systemName: model.avatarClass?.iconSystemName ?? "person.crop.circle.fill")
                    .font(.system(size: 56, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.gold)
            }
        }
    }

    private var identityBlock: some View {
        VStack(spacing: 4) {
            Text(model.displayName)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(model.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.gold)

            Text(model.effectiveClassDisplay)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    private var levelBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "number")
                .font(.caption.weight(.bold))
            Text("\(model.level)")
                .font(.callout.weight(.bold))
            Text("Level")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Color.white.opacity(0.18))
                .overlay(Capsule().strokeBorder(Color.gold.opacity(0.7), lineWidth: 1))
        )
    }

    private var xpProgressBar: some View {
        VStack(spacing: 6) {
            HStack {
                Text("XP")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("\(model.xpIntoCurrentLevel) / \(model.xpForNextLevel)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
            }
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(Color.gold)
                .accessibilityValue("\(Int(model.progress * 100)) percent")
                .frame(height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            // Structural scrim: darkens the XP block so white copy stays legible over the gradient card.
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                .fill(Color.black.opacity(0.25))
        )
    }

    private var accessoryStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars")
                .font(.caption2)
                .foregroundStyle(Color.gold)
            Text("Accessories: \(model.accessories.count)")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.92))
        }
    }

    private var accessibilityLabel: String {
        let accessoryCount = model.accessories.count
        let accessoryText = accessoryCount > 0
            ? ", \(accessoryCount) accessories"
            : ""
        return "\(model.displayName), \(model.title), level \(model.level)" +
            ", \(Int(model.progress * 100))% to next level" +
            accessoryText
    }
}
