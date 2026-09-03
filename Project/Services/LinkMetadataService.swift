//
//  LinkMetadataService.swift
//  LootList
//
//  Created by Ben Mackin on 8/29/26.
//

import Foundation
import LinkPresentation
import os
import UniformTypeIdentifiers

struct ResolvedLinkMetadata: Sendable, Equatable {
    let title: String?
    let imageURL: String?
    let originalURL: URL
}

/// Asynchronously resolves webpage metadata (title and preview image URL) from URLs.
@MainActor
final class LinkMetadataService {
    private nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "LinkMetadata")

    private final class MetadataBox: NSObject {
        let metadata: ResolvedLinkMetadata
        init(_ metadata: ResolvedLinkMetadata) {
            self.metadata = metadata
            super.init()
        }
    }

    /// Bounded cache — NSCache evicts under memory pressure; count limit prevents unbounded growth.
    private static let memoryCache: NSCache<NSURL, MetadataBox> = {
        let cache = NSCache<NSURL, MetadataBox>()
        cache.countLimit = 100
        cache.totalCostLimit = 2 * 1024 * 1024
        cache.name = "LinkMetadataService.memoryCache"
        return cache
    }()

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
    nonisolated static func fetchMetadata(for url: URL) async -> ResolvedLinkMetadata? {
        if let cached = await MainActor.run(body: { memoryCache.object(forKey: url as NSURL)?.metadata }) {
            return cached
        }

        let provider = LPMetadataProvider()
        provider.timeout = 6.0

        var title: String?
        var imageURLString: String?

        do {
            let metadata = try await provider.startFetchingMetadata(for: url)
            let rawTitle = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            title = (rawTitle?.isEmpty == false) ? rawTitle : nil

            if let imageProvider = metadata.imageProvider,
               let loaded = await loadImageURL(from: imageProvider)
            {
                imageURLString = loaded.absoluteString
            }

            if imageURLString == nil {
                imageURLString = await fetchImageURLViaHTML(for: url)
            }

            let result = ResolvedLinkMetadata(
                title: title,
                imageURL: imageURLString,
                originalURL: url
            )
            await MainActor.run { memoryCache.setObject(MetadataBox(result), forKey: url as NSURL) }
            return result
        } catch {
            logger.debug("Link metadata fetch skipped/failed for \(url.host ?? "url", privacy: .private): \(error.localizedDescription)")
            let fallbackImage = await fetchImageURLViaHTML(for: url)
            let result = ResolvedLinkMetadata(title: nil, imageURL: fallbackImage, originalURL: url)
            await MainActor.run { memoryCache.setObject(MetadataBox(result), forKey: url as NSURL) }
            return result
        }
    }

    // MARK: - Image URL Loading

    private nonisolated static func loadImageURL(from provider: NSItemProvider) async -> URL? {
        if provider.canLoadObject(ofClass: URL.self) {
            return await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { object, _ in
                    continuation.resume(returning: object as? URL)
                }
            }
        }
        if let url = await loadURL(for: UTType.url.identifier, from: provider) {
            return url
        }
        if let url = await loadURL(for: "public.url", from: provider) {
            return url
        }
        return nil
    }

    private nonisolated static func loadURL(for identifier: String, from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let str = item as? String, let url = URL(string: str) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private nonisolated static func fetchImageURLViaHTML(for url: URL) async -> String? {
        guard let html = await fetchRawHTML(for: url) else { return nil }
        return extractOGImage(from: html, baseURL: url)
    }

    /// Extracts the first og:image or twitter:image URL from HTML, resolving relative URLs against baseURL.
    nonisolated static func extractOGImage(from html: String, baseURL: URL) -> String? {
        let metaPattern = "<meta[^>]+>"
        let metaRegex: NSRegularExpression
        do {
            metaRegex = try NSRegularExpression(pattern: metaPattern, options: .caseInsensitive)
        } catch {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = metaRegex.matches(in: html, options: [], range: range)

        var ogCandidate: String?
        var twitterCandidate: String?

        for match in matches {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            let lower = tag.lowercased()

            // Prefer og:image over twitter:image — track first of each.
            if lower.contains("og:image") {
                if ogCandidate == nil, let content = extractContent(from: tag),
                   let resolved = resolvedURLString(from: content, baseURL: baseURL)
                {
                    ogCandidate = resolved
                }
            } else if lower.contains("twitter:image") {
                if twitterCandidate == nil, let content = extractContent(from: tag),
                   let resolved = resolvedURLString(from: content, baseURL: baseURL)
                {
                    twitterCandidate = resolved
                }
            }
            if ogCandidate != nil {
                break
            }
        }
        return ogCandidate ?? twitterCandidate
    }

    private nonisolated static func extractContent(from tag: String) -> String? {
        let pattern = #"content\s*=\s*["']([^"']+)["']"#
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        } catch {
            return nil
        }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, options: [], range: range),
              match.numberOfRanges > 1,
              let contentRange = Range(match.range(at: 1), in: tag) else { return nil }
        let content = String(tag[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    private nonisolated static func resolvedURLString(from content: String, baseURL: URL) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }
        if let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL.absoluteString {
            return resolved
        }
        return trimmed
    }

    nonisolated static func fetchRawHTML(for url: URL) async -> String? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else { return nil }
            let capped = data.prefix(100 * 1024)
            if let html = String(data: Data(capped), encoding: .utf8) {
                return html
            }
            return String(data: Data(capped), encoding: .isoLatin1)
        } catch {
            logger.debug("HTML fetch failed for \(url.host ?? "url", privacy: .private): \(error.localizedDescription)")
            return nil
        }
    }
}
