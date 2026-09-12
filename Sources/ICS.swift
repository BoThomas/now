import Foundation
import NowCore

// Native text discovery and palette resolution are adapters to shared materialization.
extension LinkExtractor {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func link(from event: ParsedEvent) -> URL? {
        link(from: event, urlsInText: { text in
            detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url) ?? []
        })
    }
}

extension ICSBuilder {
    static func meetings(fromICS text: String, subscription: CalendarSubscription, now: Date) -> ICSBuildResult {
        meetings(fromICS: text, subscription: subscription, now: now,
                 colorHex: subscription.colorHex.isEmpty ? Palette.hex(for: subscription.colorIndex) : subscription.colorHex,
                 detectLink: LinkExtractor.link(from:))
    }
}
