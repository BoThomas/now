import Foundation

// MARK: - Brew-management detection (top level, nonisolated — selftest-callable)

/// Decides whether the running bundle is managed by Homebrew.
///
/// Probe-verified model (brew 7.0.1, 2026-09-18; see plan/homebrew-tap.md):
/// cask apps are REAL bundles in the app directory, and the Caskroom holds a
/// tracking symlink back to them —
/// `<prefix>/Caskroom/<token>/<version>/<token>.app → installed bundle` —
/// recreated under the new version directory on every upgrade. Detection
/// therefore matches one of those tracking links against the running bundle
/// path. (The inverse model — `/Applications/now.app` being a symlink INTO
/// the Caskroom — is false for current brew; real cask apps are plain
/// directories in the app directory.)
///
/// Path reading is the platform adapter; the match decision is pure policy.
/// No `brew` CLI is ever invoked at runtime. Accepted misses (documented
/// behavior, the app then keeps the in-app updater): a non-default Homebrew
/// prefix, or a bundle manually copied elsewhere so the tracking link no
/// longer resolves to it.
enum BrewManagement {
    /// The cask token now ships under in the tap. Must stay in sync with the
    /// tap repository's `Casks/now.rb`.
    static let caskToken = "now"

    /// The default Homebrew Caskroom roots (Apple Silicon, Intel).
    static let defaultCaskroomPaths = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]

    /// One Caskroom tracking link: `…/Caskroom/now/<version>/now.app` with its
    /// raw `readlink` destination (absolute, or relative to the link's
    /// directory).
    struct TrackingLink: Equatable {
        var linkPath: String
        var destination: String
    }

    /// Policy: brew-managed iff one tracking link resolves to the running
    /// bundle path. Both sides go through the same normalization, so
    /// `/private/…` and `/…` spellings of one location still match.
    static func isBrewManaged(bundlePath: String, links: [TrackingLink]) -> Bool {
        guard let bundle = normalizedPath(bundlePath) else { return false }
        for link in links {
            if let target = resolvedDestination(of: link), target == bundle { return true }
        }
        return false
    }

    /// Normalizes an absolute path: drops a trailing slash and `.`/`..`
    /// components, and folds the `/private` prefix so `/tmp/…` and
    /// `/private/tmp/…` compare equal. Relative paths → nil.
    static func normalizedPath(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var standardized = (path as NSString).standardizingPath
        if standardized.hasPrefix("/private/"), standardized != "/private" {
            standardized = String(standardized.dropFirst("/private".count))
        }
        return standardized
    }

    /// Resolves a tracking link's destination: absolute destinations
    /// normalize directly; relative ones resolve against the link's own
    /// directory (symlink semantics).
    static func resolvedDestination(of link: TrackingLink) -> String? {
        if link.destination.hasPrefix("/") {
            return normalizedPath(link.destination)
        }
        let linkDirectory = (link.linkPath as NSString).deletingLastPathComponent
        return normalizedPath(linkDirectory + "/" + link.destination)
    }

    /// Filesystem adapter: reads the now cask's tracking links from the given
    /// Caskroom roots. Absent roots, unreadable version directories, and
    /// non-symlink entries (`.metadata`, a real bundle) are simply skipped.
    static func trackingLinks(caskroomPaths: [String] = defaultCaskroomPaths,
                              fileManager: FileManager = .default) -> [TrackingLink] {
        var links: [TrackingLink] = []
        for root in caskroomPaths {
            let tokenDirectory = (root as NSString).appendingPathComponent(caskToken)
            guard let versions = try? fileManager.contentsOfDirectory(atPath: tokenDirectory) else { continue }
            for version in versions {
                let versionDirectory = (tokenDirectory as NSString).appendingPathComponent(version)
                let linkPath = (versionDirectory as NSString).appendingPathComponent(caskToken + ".app")
                guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkPath) else { continue }
                links.append(TrackingLink(linkPath: linkPath, destination: destination))
            }
        }
        return links
    }

    /// Full detection for a bundle path. Cheap: a handful of directory reads
    /// under the default Caskroom roots, once per process at controller init.
    static func isBundleBrewManaged(bundlePath: String,
                                    caskroomPaths: [String] = defaultCaskroomPaths,
                                    fileManager: FileManager = .default) -> Bool {
        isBrewManaged(bundlePath: bundlePath,
                      links: trackingLinks(caskroomPaths: caskroomPaths, fileManager: fileManager))
    }
}
