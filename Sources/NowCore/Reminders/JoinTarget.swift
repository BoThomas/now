import Foundation

/// Resolves which URL Join should actually open. The event's link stays
/// exactly what the calendar said; only the click-time target adapts:
/// - native links (zoomus/zoommtg/msteams) open the meeting app directly when
///   it is installed, otherwise they fall back to their web form — a native
///   link is never silently dropped when the app is missing;
/// - web links upgrade to the native form only while the join-in-app setting
///   is on (default) AND an app is installed, otherwise they open in the
///   browser unchanged.
package enum JoinTarget {
    package static func resolve(link: URL, preferNative: Bool, canOpen: (URL) -> Bool) -> URL {
        if LinkExtractor.isNativeJoinLink(link) {
            if canOpen(link) { return link }
            return LinkExtractor.webForm(of: link) ?? link
        }
        if preferNative, let native = LinkExtractor.nativeForm(of: link), canOpen(native) {
            return native
        }
        return link
    }
}
