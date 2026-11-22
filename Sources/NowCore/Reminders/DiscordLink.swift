import Foundation

/// Recognizes calendar destinations and translates them without changing the stored URL.
package enum DiscordLink {
    private static let channelHosts = ["discord.com", "www.discord.com", "discordapp.com", "www.discordapp.com"]

    static func owns(_ host: String) -> Bool {
        channelHosts.contains(host) || host == "discord.gg"
    }

    package static func matches(_ url: URL) -> Bool {
        destination(url) != nil
    }

    static func nativeForm(of url: URL) -> URL? {
        guard let destination = destination(url) else { return nil }
        return converted(url, scheme: "discord", host: destination.host, path: destination.path)
    }

    static func webForm(of url: URL) -> URL? {
        guard let destination = destination(url) else { return nil }
        return converted(url, scheme: "https", host: destination.host, path: destination.path)
    }

    private static func destination(_ url: URL) -> (host: String, path: String)? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(),
              ["http", "https", "discord"].contains(scheme),
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        var segments = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.first == "" else { return nil }
        segments.removeFirst()
        if segments.last == "" { segments.removeLast() }

        if host == "discord.gg", segments.count == 1, isInviteCode(segments[0]) {
            return (host, "/\(segments[0])")
        }
        guard channelHosts.contains(host) else { return nil }
        if segments.count == 2, segments[0] == "invite", isInviteCode(segments[1]) {
            return ("discord.gg", "/\(segments[1])")
        }
        guard segments.count == 3, isID(segments[2]) else { return nil }
        switch segments[0] {
        case "channels" where isID(segments[1]) || segments[1] == "@me",
             "events" where isID(segments[1]):
            return ("discord.com", "/" + segments.joined(separator: "/"))
        default:
            return nil
        }
    }

    private static func converted(_ url: URL, scheme: String, host: String, path: String) -> URL? {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.scheme = scheme
        parts?.host = host
        parts?.percentEncodedPath = path
        return parts?.url
    }

    private static func isID(_ value: Substring) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isInviteCode(_ value: Substring) -> Bool {
        !value.isEmpty && value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }
}
