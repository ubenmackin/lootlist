//
//  JourneyMapView.swift
//  LootList
//
//  Created by Ben Mackin on 8/22/26.
//

import os
import SwiftUI
import UIKit

/// Full-screen horizontally-scrollable journey map showing the hero's progression
/// through seamlessly blended themed zones with milestone nodes along a winding path.
struct JourneyMapView: View {
    private static let logger = Logger(subsystem: "com.volcrypt.lootlist", category: "JourneyMapView")
    let journeyState: JourneyState
    let profileCache: ProfileCache

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState: AppState?
    @Environment(CKSyncEngineCoordinator.self) private var syncCoordinator: CKSyncEngineCoordinator?
    @State private var selectedMilestone: JourneyMilestone?
    @State private var animatedHeroLevel: Int = 1

    // MARK: - Layout Constants

    private let pathStrokeWidth: CGFloat = 8
    private let milestoneDotRadius: CGFloat = 11
    private let currentDotRadius: CGFloat = 15
    private let avatarSize: CGFloat = 68
    private let mascotSize: CGFloat = 36

    var body: some View {
        GeometryReader { geometry in
            let screenHeight = geometry.size.height
            let screenWidth = geometry.size.width
            let zoneWidth = max(480, screenWidth * 1.25)
            let totalMapWidth = calculateTotalMapWidth(zoneWidth: zoneWidth)
            let safeTop = geometry.safeAreaInsets.top
            let safeBottom = geometry.safeAreaInsets.bottom

            ZStack(alignment: .top) {
                // 1. Full-Screen Edge-to-Edge Scrollable World
                scrollableWorld(
                    totalMapWidth: totalMapWidth,
                    zoneWidth: zoneWidth,
                    height: screenHeight,
                    safeBottom: safeBottom
                )

                // 2. Floating Top Header Island (Safe from Status Bar)
                topHeaderBar
                    .padding(.horizontal, DesignSystemConstants.Padding.standard)
                    .padding(.top, max(64, safeTop + 28))

                // 3. Floating Bottom Milestone Inspect Card
                if let milestone = selectedMilestone {
                    milestoneInspectCard(milestone: milestone)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.horizontal, DesignSystemConstants.Padding.standard)
                        .padding(.bottom, max(24, safeBottom + 12))
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .move(edge: .bottom).combined(with: .opacity)
                        ))
                }
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
    }

    // MARK: - Scrollable World

    private func scrollableWorld(
        totalMapWidth: CGFloat,
        zoneWidth: CGFloat,
        height: CGFloat,
        safeBottom: CGFloat
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    // Continuous Multi-Layer Landscape Background
                    JourneyZoneDecorations.continuousWorldBackground(
                        totalWidth: totalMapWidth,
                        height: height
                    )

                    // Zone Landmark Features & Banners (Pill at bottom)
                    zoneFeaturesAndBanners(
                        zoneWidth: zoneWidth,
                        height: height,
                        safeBottom: safeBottom
                    )

                    // Winding Path, Nodes, and Hero Avatar
                    pathAndMilestonesCanvas(totalWidth: totalMapWidth, height: height)
                }
                .frame(width: totalMapWidth, height: height)
            }
            .onAppear {
                handleInitialLoad(proxy: proxy)
            }
        }
    }

    // MARK: - Progression Animation & Centering

    private func handleInitialLoad(proxy: ScrollViewProxy) {
        let targetLevel = journeyState.currentLevel
        let stored = profileCache.journeyMapLastSeenLevel

        if stored < targetLevel {
            // Player leveled up since last view! Start at previous level and step forward.
            animatedHeroLevel = stored
            proxy.scrollTo(stored, anchor: .center)

            Task {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    for stepLevel in (stored + 1) ... targetLevel {
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeInOut(duration: 0.85)) {
                            animatedHeroLevel = stepLevel
                            proxy.scrollTo(stepLevel, anchor: .center)
                        }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        try await Task.sleep(nanoseconds: 900_000_000)
                    }

                    guard !Task.isCancelled else { return }
                    // Monotonically acknowledge that the hero reached this level on the map,
                    // syncing across all devices via CloudKit/SwiftData.
                    await JourneyService.acknowledgeJourneyLevel(
                        targetLevel,
                        profileCache: profileCache,
                        appState: appState,
                        cacheService: appState?.cacheService,
                        syncCoordinator: syncCoordinator
                    )
                } catch {
                    Self.logger.debug("Journey level animation interrupted: \(error, privacy: .private)")
                }
            }
        } else {
            // Already current: center on target level
            animatedHeroLevel = targetLevel
            withAnimation(.easeInOut(duration: 0.5)) {
                proxy.scrollTo(targetLevel, anchor: .center)
            }
        }
    }

    // MARK: - Zone Features & Landmark Banners

    private func zoneFeaturesAndBanners(
        zoneWidth: CGFloat,
        height: CGFloat,
        safeBottom: CGFloat
    ) -> some View {
        ForEach(displayedZones, id: \.self) { zone in
            let xOffset = zoneXOffset(for: zone, zoneWidth: zoneWidth)
            let width = zoneDisplayWidth(for: zone, baseWidth: zoneWidth)

            ZStack(alignment: .bottom) {
                // Localized organic landscape elements
                JourneyZoneDecorations.zoneLandmarks(
                    for: zone,
                    zoneWidth: width,
                    height: height
                )

                // High-Contrast Frosted RPG Landmark Signpost at bottom
                zoneLandmarkBanner(for: zone)
                    .padding(.bottom, max(36, safeBottom + 16))
            }
            .frame(width: width, height: height)
            .offset(x: xOffset)
        }
    }

    // MARK: - Landmark Banner

    private func zoneLandmarkBanner(for zone: JourneyZone) -> some View {
        HStack(spacing: 8) {
            Image(systemName: zone.iconSystemName)
                .font(.subheadline.bold())
                .foregroundStyle(zone.palette.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(zone.shortName)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)

                Text(zoneLevelLabel(for: zone))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.gold)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color(red: 0.08, green: 0.10, blue: 0.16).opacity(0.88))
        )
        .overlay(
            Capsule()
                .strokeBorder(zone.palette.accentColor.opacity(0.55), lineWidth: 1.2)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 8, x: 0, y: 4)
    }

    private func zoneLevelLabel(for zone: JourneyZone) -> String {
        if zone == .eternalRealm {
            return "Levels 21+"
        }
        return "Levels \(zone.levelRange.lowerBound)–\(zone.levelRange.upperBound)"
    }

    // MARK: - Path and Milestones Canvas

    private func pathAndMilestonesCanvas(totalWidth: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            let milestones = journeyState.milestones
            guard !milestones.isEmpty else { return }

            let positions = milestonePositions(for: milestones, in: size)

            // 1. Draw base path shadow and winding stroke
            drawPath(context: context, positions: positions)

            // 2. Draw milestone nodes
            for (index, milestone) in milestones.enumerated() {
                guard index < positions.count else { break }
                drawMilestoneNode(context: context, milestone: milestone, at: positions[index])
            }
        }
        .frame(width: totalWidth, height: height)
        .overlay {
            // Hero avatar standing atop current animated node
            heroAvatarOverlay(totalWidth: totalWidth, height: height)
        }
        .contentShape(Rectangle())
        .onTapGesture { location in
            handleTap(at: location, totalWidth: totalWidth, height: height)
        }
    }

    // MARK: - Path Drawing

    private func drawPath(context: GraphicsContext, positions: [CGPoint]) {
        guard positions.count >= 2 else { return }

        // Full path trail
        var fullPath = Path()
        guard let firstPosition = positions.first else { return }
        fullPath.move(to: firstPosition)

        for index in 1 ..< positions.count {
            let prev = positions[index - 1]
            let curr = positions[index]
            let midX = (prev.x + curr.x) / 2
            fullPath.addCurve(
                to: curr,
                control1: CGPoint(x: midX, y: prev.y),
                control2: CGPoint(x: midX, y: curr.y)
            )
        }

        // Soft ground shadow under path
        context.stroke(
            fullPath,
            with: .color(Color.black.opacity(0.35)),
            style: StrokeStyle(lineWidth: pathStrokeWidth + 4, lineCap: .round, lineJoin: .round)
        )

        // Base stone path line
        context.stroke(
            fullPath,
            with: .color(Color.white.opacity(0.30)),
            style: StrokeStyle(lineWidth: pathStrokeWidth, lineCap: .round, lineJoin: .round)
        )

        // Completed Golden Path Trail (up to animated hero level)
        let currentIndex = journeyState.milestones.firstIndex { $0.level == animatedHeroLevel } ?? 0
        let reachedPositions = Array(positions.prefix(currentIndex + 1))

        if reachedPositions.count >= 2, let firstReached = reachedPositions.first {
            var reachedPath = Path()
            reachedPath.move(to: firstReached)
            for index in 1 ..< reachedPositions.count {
                let prev = reachedPositions[index - 1]
                let curr = reachedPositions[index]
                let midX = (prev.x + curr.x) / 2
                reachedPath.addCurve(
                    to: curr,
                    control1: CGPoint(x: midX, y: prev.y),
                    control2: CGPoint(x: midX, y: curr.y)
                )
            }

            // Outer gold glow
            context.stroke(
                reachedPath,
                with: .color(Color.gold.opacity(0.5)),
                style: StrokeStyle(lineWidth: pathStrokeWidth + 3, lineCap: .round, lineJoin: .round)
            )

            // Core gold path
            context.stroke(
                reachedPath,
                with: .color(Color.gold),
                style: StrokeStyle(lineWidth: pathStrokeWidth, lineCap: .round, lineJoin: .round)
            )
        }
    }

    // MARK: - Milestone Node Drawing

    private func drawMilestoneNode(context: GraphicsContext, milestone: JourneyMilestone, at point: CGPoint) {
        let isCurrent = milestone.level == animatedHeroLevel
        let isReached = milestone.level < animatedHeroLevel
        let radius = isCurrent ? currentDotRadius : milestoneDotRadius

        // Node Drop Shadow
        let shadowRect = CGRect(x: point.x - radius, y: point.y - radius + 2, width: radius * 2, height: radius * 2)
        context.fill(Circle().path(in: shadowRect), with: .color(Color.black.opacity(0.35)))

        if isReached {
            // Gold Embossed Node
            let outerRect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Circle().path(in: outerRect), with: .color(Color.gold))

            let innerRadius = radius * 0.70
            let innerRect = CGRect(x: point.x - innerRadius, y: point.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2)
            context.fill(Circle().path(in: innerRect), with: .color(Color(red: 0.95, green: 0.75, blue: 0.15)))

            let shineRadius = radius * 0.35
            let shineRect = CGRect(x: point.x - innerRadius * 0.6, y: point.y - innerRadius * 0.6, width: shineRadius, height: shineRadius)
            context.fill(Circle().path(in: shineRect), with: .color(Color.white.opacity(0.7)))
        } else if isCurrent {
            // Radiant Beacon Node with Zone Accent
            let pulseRadius = radius * 1.6
            let pulseRect = CGRect(x: point.x - pulseRadius, y: point.y - pulseRadius, width: pulseRadius * 2, height: pulseRadius * 2)
            context.fill(
                Circle().path(in: pulseRect),
                with: .color(milestone.zone.palette.accentColor.opacity(0.35))
            )

            let outerRect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Circle().path(in: outerRect), with: .color(.white))

            let coreRadius = radius * 0.75
            let coreRect = CGRect(x: point.x - coreRadius, y: point.y - coreRadius, width: coreRadius * 2, height: coreRadius * 2)
            context.fill(Circle().path(in: coreRect), with: .color(milestone.zone.palette.accentColor))
        } else {
            // Stone / Translucent Node
            let outerRect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.fill(
                Circle().path(in: outerRect),
                with: .color(Color(red: 0.12, green: 0.14, blue: 0.20).opacity(0.75))
            )
            context.stroke(
                Circle().path(in: outerRect),
                with: .color(Color.white.opacity(0.45)),
                lineWidth: 1.5
            )
        }
    }

    // MARK: - Hero Avatar Overlay

    @ViewBuilder
    private func heroAvatarOverlay(totalWidth: CGFloat, height: CGFloat) -> some View {
        let milestones = journeyState.milestones
        let positions = milestonePositions(
            for: milestones,
            in: CGSize(width: totalWidth, height: height)
        )
        if let currentIndex = milestones.firstIndex(where: { $0.level == animatedHeroLevel }),
           currentIndex < positions.count
        {
            let pos = positions[currentIndex]
            let zone = JourneyZone.zone(forLevel: animatedHeroLevel)
            let companion = MascotCompanion(rawValue: profileCache.mascotCompanion ?? "cat") ?? .cat
            let mascotSprite = MascotSpriteRenderer.sprite(for: companion, state: .idle, frameIndex: 0)

            let preset: AvatarPreset? = if let id = profileCache.avatarName {
                AvatarPreset(rawValue: id) ?? AvatarPreset.resolve(profileCache.avatarClassEnum, id: id)
            } else if let cls = profileCache.avatarClassEnum {
                AvatarPreset.presets(for: cls).first
            } else {
                nil
            }

            let heroSprite = HeroAvatarSprites.sprite(for: preset ?? .knightV1, equippedGear: profileCache.equippedItems ?? [])

            VStack(spacing: 3) {
                HStack(alignment: .bottom, spacing: -4) {
                    // Mascot Companion floating/walking alongside the hero
                    PixelCanvasView(sprite: mascotSprite, animated: true)
                        .frame(width: mascotSize, height: mascotSize)
                        .shadow(color: Color.black.opacity(0.4), radius: 4, x: 0, y: 2)
                        .offset(y: -4)

                    // Hero character with equipped gear and accessories
                    PixelCanvasView(sprite: heroSprite, animated: true)
                        .frame(width: avatarSize, height: avatarSize)
                        .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)
                }

                // Level Badge Pill
                Text("Lv. \(animatedHeroLevel)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(zone.palette.accentColor)
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 3, x: 0, y: 2)
            }
            .id(animatedHeroLevel)
            .position(x: pos.x, y: pos.y - avatarSize * 0.82)
        }
    }

    // MARK: - Milestone Positions

    private func milestonePositions(for milestones: [JourneyMilestone], in size: CGSize) -> [CGPoint] {
        guard !milestones.isEmpty else { return [] }

        let count = milestones.count
        let horizontalPadding: CGFloat = 80
        let usableWidth = max(1, size.width - horizontalPadding * 2)
        let spacing = count > 1 ? usableWidth / CGFloat(count - 1) : 0

        let centerY = size.height * 0.50
        let amplitude = size.height * 0.09

        return milestones.indices.map { index in
            let xPos = horizontalPadding + CGFloat(index) * spacing
            let phase = Double(index) * .pi / 3.0
            let yOffset = sin(phase) * amplitude
            return CGPoint(x: xPos, y: centerY + yOffset)
        }
    }

    // MARK: - Tap Handling

    private func handleTap(at location: CGPoint, totalWidth: CGFloat, height: CGFloat) {
        let milestones = journeyState.milestones
        let positions = milestonePositions(
            for: milestones,
            in: CGSize(width: totalWidth, height: height)
        )

        let tapRadius: CGFloat = 32
        var closestIndex: Int?
        var closestDistance: CGFloat = .infinity

        for (index, pos) in positions.enumerated() {
            let distance = hypot(location.x - pos.x, location.y - pos.y)
            if distance < tapRadius, distance < closestDistance {
                closestDistance = distance
                closestIndex = index
            }
        }

        if let index = closestIndex {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                if selectedMilestone?.level == milestones[index].level {
                    selectedMilestone = nil
                } else {
                    selectedMilestone = milestones[index]
                }
            }
        } else {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedMilestone = nil
            }
        }
    }

    // MARK: - Top Header Bar

    private var topHeaderBar: some View {
        let currentZone = JourneyZone.zone(forLevel: animatedHeroLevel)

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Journey Map")
                    .font(.headline.bold())
                    .foregroundStyle(.white)

                HStack(spacing: 4) {
                    Image(systemName: currentZone.iconSystemName)
                        .font(.caption2.bold())
                        .foregroundStyle(currentZone.palette.accentColor)

                    Text(currentZone.displayName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .accessibilityLabel("Close journey map")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.06, green: 0.08, blue: 0.12).opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.4), radius: 10, x: 0, y: 4)
    }

    // MARK: - Milestone Inspect Card

    private func milestoneInspectCard(milestone: JourneyMilestone) -> some View {
        VStack(spacing: 12) {
            // Header Row: Status Badge & Close
            HStack {
                statusBadge(for: milestone)

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedMilestone = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
            }

            // Milestone Title & Zone Name
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(milestone.zone.palette.accentColor.opacity(0.2))
                    Image(systemName: milestone.zone.iconSystemName)
                        .font(.title3.bold())
                        .foregroundStyle(milestone.zone.palette.accentColor)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Level \(milestone.level) — \(milestone.title)")
                        .font(.title3.bold())
                        .foregroundStyle(Color.gold)
                        .lineLimit(1)

                    Text(milestone.zone.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                }

                Spacer()
            }

            Divider()
                .background(Color.white.opacity(0.15))

            // XP and Flavor Quote
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("XP Requirement")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("\(milestone.xpRequired) Total XP")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }

                Spacer()
            }

            Text("\"\(milestone.zone.flavorText)\"")
                .font(.caption.italic())
                .foregroundStyle(.white.opacity(0.80))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(3)
        }
        .padding(DesignSystemConstants.Padding.standard)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .fill(Color(red: 0.08, green: 0.10, blue: 0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.75), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.6), radius: 16, x: 0, y: 8)
    }

    @ViewBuilder
    private func statusBadge(for milestone: JourneyMilestone) -> some View {
        let isCurrent = milestone.level == animatedHeroLevel
        let isReached = milestone.level < animatedHeroLevel

        if isReached {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                Text("COMPLETED")
            }
            .font(.caption2.bold())
            .foregroundStyle(Color.gold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.gold.opacity(0.18)))
            .overlay(Capsule().strokeBorder(Color.gold.opacity(0.4), lineWidth: 1))
        } else if isCurrent {
            HStack(spacing: 4) {
                Circle()
                    .fill(milestone.zone.palette.accentColor)
                    .frame(width: 6, height: 6)
                Text("CURRENT LEVEL")
            }
            .font(.caption2.bold())
            .foregroundStyle(milestone.zone.palette.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(milestone.zone.palette.accentColor.opacity(0.18)))
            .overlay(Capsule().strokeBorder(milestone.zone.palette.accentColor.opacity(0.5), lineWidth: 1))
        } else {
            HStack(spacing: 4) {
                Image(systemName: "lock.fill")
                Text("LOCKED")
            }
            .font(.caption2.bold())
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.1)))
        }
    }

    // MARK: - Layout Helpers

    private var displayedZones: [JourneyZone] {
        JourneyZone.allCases
    }

    private func zoneDisplayWidth(for zone: JourneyZone, baseWidth: CGFloat) -> CGFloat {
        if zone == .eternalRealm {
            return baseWidth * 2.0
        }
        return baseWidth
    }

    private func calculateTotalMapWidth(zoneWidth: CGFloat) -> CGFloat {
        displayedZones.reduce(0) { sum, zone in
            sum + zoneDisplayWidth(for: zone, baseWidth: zoneWidth)
        }
    }

    private func zoneXOffset(for zone: JourneyZone, zoneWidth: CGFloat) -> CGFloat {
        var offset: CGFloat = 0
        for current in displayedZones {
            if current == zone {
                break
            }
            offset += zoneDisplayWidth(for: current, baseWidth: zoneWidth)
        }
        return offset
    }
}
