//
//  LinkMetadataService.swift
//  LootList
//
//  Created by Ben Mackin on 8/29/26.
//

import Foundation
import LinkPresentation
import os

struct ResolvedLinkMetadata: Sendable, Equatable {
    let title: String?
    let imageURL: String?
    let originalURL: URL
}

/// Asynchronously resolves webpage metadata (title and preview image URL) from URLs.
@MainActor
final class LinkMetadataService {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "LinkMetadata")

    /// Cache resolved metadata to avoid redundant network requests.
    private static var memoryCache: [URL: ResolvedLinkMetadata] = [:]

    /// Validates and normalizes user-entered URL strings.
    nonisolated static func normalizeURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
            ? trimmed
            : "https://" + trimmed

        guard let url = URL(string: withScheme),
              let host = url.host,
              host.contains(".")
        else {
            return nil
        }
        return url
    }

    /// Fetches title and preview image for a URL with a timeout guard.
    static func fetchMetadata(for url: URL) async -> ResolvedLinkMetadata? {
        if let cached = memoryCache[url] {
            return cached
        }

        let provider = LPMetadataProvider()
        provider.timeout = 6.0

        do {
            let metadata = try await provider.startFetchingMetadata(for: url)
            let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let imageURL = metadata.imageProvider != nil ? url.absoluteString : nil

            let result = ResolvedLinkMetadata(
                title: (title?.isEmpty == false) ? title : nil,
                imageURL: imageURL,
                originalURL: url
            )
            memoryCache[url] = result
            return result
        } catch {
            logger.debug("Link metadata fetch skipped/failed for \(url.host ?? "url", privacy: .private): \(error.localizedDescription)")
            return ResolvedLinkMetadata(title: nil, imageURL: nil, originalURL: url)
        }
    }
}
