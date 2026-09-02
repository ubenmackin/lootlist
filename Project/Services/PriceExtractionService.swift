//
//  PriceExtractionService.swift
//  LootList
//
//  Created by Ben Mackin on 9/01/26.
//

import Foundation
import os
#if canImport(FoundationModels)
    import FoundationModels
#endif

struct ExtractedPrice: Sendable {
    let amount: Double
    let currency: String
    let confidence: String
}

@MainActor
enum PriceExtractionService {
    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "PriceExtraction"
    )

    nonisolated static func extractPrice(from url: URL) async -> ExtractedPrice? {
        guard let html = await fetchRawHTML(for: url) else { return nil }
        let cleaned = stripScriptsAndStyles(from: html)
        let snippet = String(cleaned.prefix(8000))
        guard !snippet.isEmpty else { return nil }

        #if canImport(FoundationModels)
            if #available(iOS 26, *) {
                if SystemLanguageModel.default.isAvailable {
                    if let fmPrice = await extractWithFoundationModels(snippet: snippet) {
                        if fmPrice.amount > 0, fmPrice.amount < 100_000 {
                            return fmPrice
                        }
                    }
                }
            }
        #endif

        return extractWithRegex(from: snippet, fullHTML: html)
    }

    nonisolated static func fetchRawHTML(for url: URL) async -> String? {
        await LinkMetadataService.fetchRawHTML(for: url)
    }

    // MARK: - HTML Cleaning

    private nonisolated static func stripScriptsAndStyles(from html: String) -> String {
        var cleaned = html
        // Remove script/style blocks — they add noise and can contain false price matches.
        let patterns = [
            "<script[^>]*>.*?</script>",
            "<style[^>]*>.*?</style>"
        ]
        for pattern in patterns {
            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
            } catch {
                continue
            }
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }
        return cleaned
    }

    // MARK: - Foundation Models

    #if canImport(FoundationModels)
        @available(iOS 26, *)
        private nonisolated static func extractWithFoundationModels(snippet: String) async -> ExtractedPrice? {
            let session = LanguageModelSession()
            let instruction = """
            Extract the product price from the HTML snippet below.
            Respond ONLY with valid JSON: {"price": number|null, "currency": "USD", "confidence": "high"|"medium"|"low"}.
            Use null if no price found. Currency is 3-letter code default USD.
            HTML snippet:
            \(snippet)
            """
            do {
                let response = try await session.respond(to: instruction)
                // Convert response to string regardless of concrete type — handles content vs description differences.
                let text = "\(response)"
                if let price = parseFMJSON(text) {
                    return price
                }
                // Try extracting JSON substring if response contains surrounding prose.
                if let jsonSlice = extractJSONString(from: text), let price = parseFMJSON(jsonSlice) {
                    return price
                }
                return nil
            } catch {
                logger.debug("FoundationModels prompt failed: \(error.localizedDescription, privacy: .private)")
                return nil
            }
        }

        private nonisolated static func extractJSONString(from text: String) -> String? {
            guard let start = text.firstIndex(of: "{"),
                  let end = text.lastIndex(of: "}") else { return nil }
            return String(text[start ... end])
        }

        private nonisolated static func parseFMJSON(_ jsonString: String) -> ExtractedPrice? {
            guard let data = jsonString.data(using: .utf8) else { return nil }
            let jsonObject: Any
            do {
                jsonObject = try JSONSerialization.jsonObject(with: data)
            } catch {
                return nil
            }
            guard let obj = jsonObject as? [String: Any] else { return nil }

            let rawPrice: Double? = {
                if let num = obj["price"] as? Double {
                    return num
                }
                if let num = obj["price"] as? Int {
                    return Double(num)
                }
                if let str = obj["price"] as? String {
                    return Double(str)
                }
                if obj["price"] is NSNull {
                    return nil
                }
                return nil
            }()
            guard let price = rawPrice, price > 0, price < 100_000 else { return nil }

            let currency = (obj["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let resolvedCurrency: String = {
                if let currencyValue = currency, currencyValue.count == 3 {
                    return currencyValue
                }
                return CurrencyFormatter.currencyCode
            }()

            let confidence = (obj["confidence"] as? String)?.lowercased() ?? "medium"
            let resolvedConfidence = ["high", "medium", "low"].contains(confidence) ? confidence : "medium"

            return ExtractedPrice(amount: price, currency: resolvedCurrency, confidence: resolvedConfidence)
        }
    #endif

    // MARK: - Deterministic Regex Fallback

    private nonisolated static func extractWithRegex(from snippet: String, fullHTML: String) -> ExtractedPrice? {
        // Prefer meta tags — highest signal for product price.
        let currency = extractCurrency(from: fullHTML)

        if let raw = extractMetaAmount(for: "og:price:amount", in: fullHTML),
           let amount = parseAmountString(raw),
           amount > 0, amount < 100_000
        {
            return ExtractedPrice(amount: amount, currency: currency, confidence: "high")
        }

        if let raw = extractMetaAmount(for: "product:price:amount", in: fullHTML),
           let amount = parseAmountString(raw),
           amount > 0, amount < 100_000
        {
            return ExtractedPrice(amount: amount, currency: currency, confidence: "high")
        }

        // JSON-LD "price" — structured data fallback.
        if let raw = extractJSONLDPrice(from: fullHTML),
           let amount = parseAmountString(raw),
           amount > 0, amount < 100_000
        {
            return ExtractedPrice(amount: amount, currency: currency, confidence: "medium")
        }

        // Also try snippet for JSON-LD when fullHTML is large but snippet contains the block.
        if let raw = extractJSONLDPrice(from: snippet),
           let amount = parseAmountString(raw),
           amount > 0, amount < 100_000
        {
            return ExtractedPrice(amount: amount, currency: currency, confidence: "medium")
        }

        return nil
    }

    private nonisolated static func extractMetaAmount(for key: String, in html: String) -> String? {
        // Scan meta tags and match property/name containing key, then pull content attribute.
        let metaPattern = "<meta[^>]+>"
        let metaRegex: NSRegularExpression
        do {
            metaRegex = try NSRegularExpression(pattern: metaPattern, options: .caseInsensitive)
        } catch {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = metaRegex.matches(in: html, options: [], range: range)
        for match in matches {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            if tag.lowercased().contains(key.lowercased()) {
                if let content = extractContentAttribute(from: tag) {
                    return content
                }
            }
        }
        return nil
    }

    private nonisolated static func extractCurrency(from html: String) -> String {
        if let raw = extractMetaAmount(for: "og:price:currency", in: html) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if trimmed.count == 3 {
                return trimmed
            }
        }
        if let raw = extractMetaAmount(for: "product:price:currency", in: html) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if trimmed.count == 3 {
                return trimmed
            }
        }
        // JSON-LD priceCurrency
        let currencyPattern = #"priceCurrency"\s*:\s*["']?([A-Za-z]{3})["']?"#
        let currencyRegex: NSRegularExpression
        do {
            currencyRegex = try NSRegularExpression(pattern: currencyPattern, options: .caseInsensitive)
        } catch {
            return CurrencyFormatter.currencyCode
        }
        let range = NSRange(html.startIndex..., in: html)
        if let match = currencyRegex.firstMatch(in: html, options: [], range: range),
           match.numberOfRanges > 1,
           let currencyRange = Range(match.range(at: 1), in: html)
        {
            let code = String(html[currencyRange]).uppercased()
            if code.count == 3 {
                return code
            }
        }
        return CurrencyFormatter.currencyCode
    }

    private nonisolated static func extractJSONLDPrice(from html: String) -> String? {
        let pattern = #""price"\s*:\s*["']?([0-9]+(?:[.,][0-9]+)?)["']?"#
        let priceRegex: NSRegularExpression
        do {
            priceRegex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        } catch {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        if let match = priceRegex.firstMatch(in: html, options: [], range: range),
           match.numberOfRanges > 1,
           let priceRange = Range(match.range(at: 1), in: html)
        {
            return String(html[priceRange])
        }
        return nil
    }

    private nonisolated static func extractContentAttribute(from tag: String) -> String? {
        let pattern = #"content\s*=\s*["']([^"']+)["']"#
        let contentRegex: NSRegularExpression
        do {
            contentRegex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        } catch {
            return nil
        }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = contentRegex.firstMatch(in: tag, options: [], range: range),
              match.numberOfRanges > 1,
              let contentRange = Range(match.range(at: 1), in: tag) else { return nil }
        let content = String(tag[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return content.isEmpty ? nil : content
    }

    private nonisolated static func parseAmountString(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Strip currency symbols and keep digits, comma, dot.
        let cleaned = trimmed.replacingOccurrences(of: ",", with: "")
        if let direct = Double(cleaned), direct.isFinite {
            return direct
        }
        // Fallback: extract first numeric token.
        let numPattern = #"([0-9]+(?:\.[0-9]+)?)"#
        let numberRegex: NSRegularExpression
        do {
            numberRegex = try NSRegularExpression(pattern: numPattern)
        } catch {
            return nil
        }
        if let match = numberRegex.firstMatch(in: cleaned, options: [], range: NSRange(cleaned.startIndex..., in: cleaned)),
           let numberRange = Range(match.range(at: 1), in: cleaned)
        {
            return Double(String(cleaned[numberRange]))
        }
        return nil
    }
}
