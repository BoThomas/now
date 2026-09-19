import Foundation
import NowCore

/// Portable text URL discovery for non-Apple platforms: an explicit scanner
/// replacing the `NSDataDetector` adapter. It only produces candidates; core's
/// `LinkExtractor` keeps owning selection, provider shapes and join conversion.
/// This is a deliberate first-port adapter, not a claim of NSDataDetector parity.
enum PortableLinkDetector {
    static let maxTextLength = 100_000
    static let maxURLs = 32

    static func urls(inText text: String) -> [URL] {
        guard !text.isEmpty, text.utf16.count <= maxTextLength else { return [] }
        // ICS descriptions frequently double-encode separators ("&amp;"); scan
        // both the raw text and its entity-decoded form, like tolerant shells do.
        return candidates(in: [text, LinkExtractor.decodeHTMLEntities(text)])
    }

    private static func candidates(in texts: [String]) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        for text in texts {
            for token in text.split(whereSeparator: { $0.isWhitespace || "()<>\"'|[]{}".contains($0) }) {
                guard urls.count < maxURLs else { return urls }
                guard let url = url(fromToken: String(token)), seen.insert(url.absoluteString).inserted else { continue }
                urls.append(url)
            }
        }
        return urls
    }

    /// Accepts explicit http(s) tokens only; trims sentence punctuation that
    /// NSDataDetector would not treat as part of the link.
    private static func url(fromToken token: String) -> URL? {
        let lowered = token.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return nil }
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?'\""))
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty,
              url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else { return nil }
        return url
    }
}
