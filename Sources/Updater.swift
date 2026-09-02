import Foundation
import AppKit
import Security
import Darwin

// MARK: - Pure decision layer (top level, nonisolated — selftest-callable)

/// One viable GitHub release: parsed, asset-matched, ready to be decided on.
struct UpdateManifest: Equatable {
    var version: String        // "1.5.0" — parsed from tag "v1.5.0"
    var zipURL: URL            // browser_download_url of the matched asset
    var assetSize: Int         // assets[].size — cross-checked after download
    var publishedAt: Date      // age gate for automatic checks
    var notes: String          // release body, raw
}

enum UpdateDecision: Equatable {
    case upToDate              // also covers: release younger than the age gate
    case available(UpdateManifest)
    case skippedVersion(String)   // matches settings.skippedUpdateVersion
    case error(String)            // parse/network reason (UI shows only on manual check)
}

/// Ephemeral update bookkeeping — a separate UserDefaults payload, deliberately
/// NOT part of `Persisted` (subscriptions + settings). The `--update-*` CLI
/// modes never write it; only the running app does.
struct UpdateState: Codable, Equatable {
    var lastSuccessCheckDate: Date?
    var lastAttemptDate: Date?
    var attemptsToday: Int = 0
    /// Local calendar day ("2026-08-30") the attempt counter belongs to.
    var attemptsDayStamp: String = ""
    /// Set when the update window is SHOWN for a version — never when a check
    /// merely discovers it (a deferred window must not suppress itself).
    var lastNotifiedVersion: String?
    var firstSeenUpdateVersion: String?
    var firstSeenUpdateDate: Date?
    /// Version whose install helper we spawned — on a failed-update relaunch
    /// this becomes `lastNotifiedVersion` so the failed version never nags.
    var pendingInstallVersion: String?

    init() {}
}

enum UpdateLogic {
    static let updateBundleIdentifier = "com.thomasboch.now"

    /// Certificate SHA-1 fingerprints accepted for staged updates — the same
    /// anchors that keep Calendar (TCC) grants stable across releases (see
    /// build-app.sh / AGENTS.md → Code signing). Rotation procedure: ADD the
    /// new fingerprint while still signing with the old cert, keep that up for
    /// several releases, then switch and later remove the old entry. Clients
    /// older than the release that added the new fingerprint strand on manual
    /// downloads once the switch happens — accepted for this user base.
    static let pinnedFingerprints = ["A505B08900C56A28709479297A049525A2A187C6"]

    /// Designated requirement a staged bundle must satisfy (same text form
    /// build-app.sh verifies against: lowercase hex, no colons).
    static func updateRequirement(fingerprint: String, bundleIdentifier: String = updateBundleIdentifier) -> String {
        "identifier \"\(bundleIdentifier)\" and certificate root = H\"\(fingerprint.lowercased())\""
    }

    /// "v1.5.0" → "1.5.0"; anything but v + exactly three numeric components → nil.
    static func version(fromTag tag: String) -> String? {
        guard tag.hasPrefix("v") else { return nil }
        let raw = String(tag.dropFirst())
        guard let parts = strictVersionComponents(raw), parts.count == 3 else { return nil }
        return raw
    }

    /// Numeric components of a dotted version string; non-numeric parts → empty.
    static func versionComponents(_ version: String) -> [Int] {
        version.split(separator: ".").compactMap { Int($0) }
    }

    /// STRICT variant: every dot-component must be canonical ASCII decimal
    /// (no signs, leading zeroes, or
    /// "1.5.0-beta.1", no dropped junk) — lenient `compactMap` parsing made
    /// prerelease tags masquerade as valid versions.
    static func strictVersionComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let value = Int(part),
                  part == String(value) else { return nil }
            result.append(value)
        }
        return result
    }

    /// Strictly-greater 3-component semver ("no downgrades, equal = up to date").
    /// Comparison is component-wise ([1,10,0] > [1,9,9]).
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard let a = strictVersionComponents(candidate),
              let b = strictVersionComponents(current),
              a.count == 3, b.count == 3 else { return false }
        return orderedVersionComponents(a, b) == 1
    }

    /// Lexicographic ordering of numeric version components; a shorter list
    /// counts as zero-padded ("13" equals [13, 0, 0]). Returns -1 / 0 / 1.
    static func orderedVersionComponents(_ a: [Int], _ b: [Int]) -> Int {
        let count = max(a.count, b.count)
        for index in 0..<count {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// The decision pipeline for one fetched release. `minAge` is 0 for manual
    /// checks and 24 h for automatic ones (the delete-a-bad-release brake).
    static func decide(manifest: UpdateManifest?, currentVersion: String, skipped: String?, now: Date, minAge: TimeInterval) -> UpdateDecision {
        guard let manifest else { return .error("no usable release") }
        if !isVersion(manifest.version, newerThan: currentVersion) { return .upToDate }
        if let skipped, skipped == manifest.version { return .skippedVersion(manifest.version) }
        if now.timeIntervalSince(manifest.publishedAt) < minAge { return .upToDate }
        return .available(manifest)
    }

    /// Local calendar day stamp for the attempt counter.
    static func dayStamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Throttle for automatic checks: a SUCCESS silences for 24 h; a FAILURE
    /// retries after ≥ 1 h, at most 3 attempts per day (a network blip at
    /// launch must not silence checks for a whole day). Manual checks bypass.
    static func shouldAutoCheck(state: UpdateState, now: Date, calendar: Calendar = .current) -> Bool {
        let stamp = dayStamp(now, calendar: calendar)
        let attempts = state.attemptsDayStamp == stamp ? state.attemptsToday : 0
        if attempts >= 3 { return false }
        if let attempt = state.lastAttemptDate, now.timeIntervalSince(attempt) < 3600 { return false }
        if let success = state.lastSuccessCheckDate, now.timeIntervalSince(success) < 24 * 3600 { return false }
        return true
    }

    /// Escalation: auto-checks light the menu quietly; the window auto-shows
    /// once per version only after it sat uninstalled for ~3 days.
    static let escalationDwell: TimeInterval = 3 * 86400

    static func shouldEscalate(availableVersion: String, state: UpdateState, now: Date) -> Bool {
        guard let seen = state.firstSeenUpdateVersion, seen == availableVersion,
              let seenDate = state.firstSeenUpdateDate else { return false }
        if state.lastNotifiedVersion == availableVersion { return false }
        return now.timeIntervalSince(seenDate) >= escalationDwell
    }

    static func shouldStageUpdate(version: String, userInitiated: Bool, state: UpdateState) -> Bool {
        userInitiated || state.lastNotifiedVersion != version
    }

    /// Release body → window text: drops release.sh's trailing
    /// "Full changelog: …" line and surrounding blank lines.
    static func displayNotes(_ body: String) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespaces).isEmpty || last.hasPrefix("Full changelog:") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One renderable element of a release body: real changelogs are often
    /// multiple lists under `#`/`##` headings (release.sh `--notes` keeps
    /// heading and bullet lines), not one flat list.
    enum NoteBlock: Equatable {
        case heading(level: Int, text: String)
        case bullet(text: String)
        case paragraph(text: String)
    }

    /// Line-based parse of a release body into `NoteBlock`s (input already
    /// goes through `displayNotes`). Consecutive non-empty plain lines merge
    /// into one paragraph; heading level is capped at 3.
    static func noteBlocks(_ body: String) -> [NoteBlock] {
        var blocks: [NoteBlock] = []
        var paragraph: [String] = []
        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(text: paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }
        for rawLine in displayNotes(body).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("#") {
                flushParagraph()
                let hashes = line.prefix(while: { $0 == "#" }).count
                let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { blocks.append(.heading(level: min(hashes, 3), text: text)) }
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(text: String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if line == "-" || line == "*" {
                flushParagraph()
                blocks.append(.bullet(text: ""))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }

    /// Staged LSMinimumSystemVersion vs the running OS — a future deployment
    /// bump must refuse instead of installing an app that can't launch.
    static func meetsMinimumSystemVersion(required: String?, osMajor: Int, osMinor: Int, osPatch: Int) -> Bool {
        guard let required,
              let parts = strictVersionComponents(required),
              (1...3).contains(parts.count) else { return false }
        return orderedVersionComponents([osMajor, osMinor, osPatch], parts) >= 0
    }

    /// Install-location refusals: translocated copies and disk images can't be
    /// updated in place. Returns a user-facing reason, or nil when installable.
    static func installLocationProblem(_ bundlePath: String) -> String? {
        if bundlePath.contains("/App Translocation/") {
            return "now is running from a translocated copy. Drag it to /Applications, launch it there, then update."
        }
        if bundlePath.hasPrefix("/Volumes/") {
            return "now is running from a disk image. Drag it to /Applications, launch it there, then update."
        }
        return nil
    }

    // MARK: GitHub release JSON

    struct GitHubLatestRelease: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let published_at: String?
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int
        }
    }

    /// Strict parse of `GET /repos/:owner/:repo/releases/latest`: tag must be
    /// v + x.y.z and the matching `now-vX.Y.Z.zip` asset must exist. A missing
    /// or unparsable `published_at` counts as "just released" (age gate keeps
    /// blocking automatic offers; manual checks still work).
    static func parseLatestRelease(_ data: Data, appName: String = "now", now: Date = Date()) -> UpdateManifest? {
        guard let release = try? JSONDecoder().decode(GitHubLatestRelease.self, from: data) else { return nil }
        guard let version = version(fromTag: release.tag_name) else { return nil }
        let assetName = "\(appName)-v\(version).zip"
        guard let asset = release.assets.first(where: { $0.name == assetName }) else { return nil }
        guard let url = URL(string: asset.browser_download_url) else { return nil }
        let published: Date
        if let iso = release.published_at, let parsed = ISO8601DateFormatter().date(from: iso) {
            published = parsed
        } else {
            published = now
        }
        return UpdateManifest(version: version, zipURL: url, assetSize: max(0, asset.size), publishedAt: published, notes: release.body ?? "")
    }

    /// The running app's marketing version, normalized to three components
    /// (release.sh does the same when reading Info.plist).
    static var currentVersion: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        let parts = versionComponents(raw)
        if parts.count == 3 { return raw }
        if parts.count == 2 { return "\(raw).0" }
        return "0.0.0"
    }

    static var currentBuild: Int {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) ?? 0
    }

    static func stateAfterInstallFailure(_ old: UpdateState) -> UpdateState {
        var state = old
        if let pending = state.pendingInstallVersion {
            state.lastNotifiedVersion = pending
        }
        state.pendingInstallVersion = nil
        return state
    }

    /// A successful install relaunches the app AS the pending version: when
    /// the running version matches the pending marker, the update landed and
    /// the relaunched app confirms it with the installed window. The failure
    /// path can never match — it restores and relaunches the OLD version
    /// (with `NOW_UPDATE_ERROR`) instead.
    static func justInstalledVersion(pending: String?, currentVersion: String) -> String? {
        guard let pending, pending == currentVersion else { return nil }
        return pending
    }

    static func stateAfterSuccessfulInstall(_ old: UpdateState) -> UpdateState {
        var state = old
        state.pendingInstallVersion = nil
        return state
    }

    static func stateAfterShowingUpdate(_ old: UpdateState, version: String?) -> UpdateState {
        guard let version else { return old }
        var state = old
        state.lastNotifiedVersion = version
        return state
    }
}

// MARK: - Network fetch (nonisolated)

enum UpdateFetch {
    struct Outcome {
        var data: Data?
        var status: Int?
        var error: String?
    }

    static var apiBaseOverride: String? { ProcessInfo.processInfo.environment["NOW_UPDATE_API_BASE"] }
    static var repoOverride: String? { ProcessInfo.processInfo.environment["NOW_UPDATE_REPO"] }

    /// `--update-check http://…` / env override resolution for the API base.
    static func resolvedBase(_ argument: String?) -> String {
        argument ?? apiBaseOverride ?? "https://api.github.com"
    }

    static func resolvedRepo(_ argument: String?) -> String {
        argument ?? repoOverride ?? "BoThomas/now"
    }

    /// Bearer token only ever considered for overridden (test) endpoints —
    /// production is public and unauthenticated.
    static func authToken(base: String) -> String? {
        guard base != "https://api.github.com" else { return nil }
        return ProcessInfo.processInfo.environment["NOW_UPDATE_TOKEN"]
    }

    static func userAgent() -> String {
        "now/\(UpdateLogic.currentVersion)"
    }

    static func latestReleaseURL(base: String, repo: String) -> URL? {
        URL(string: "\(base)/repos/\(repo)/releases/latest")
    }

    static func isSuccessfulStatus(_ status: Int?) -> Bool {
        status.map { (200...299).contains($0) } ?? false
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// Production permits HTTPS only. HTTP exists solely for the local smoke
    /// server and is enabled only by an explicit loopback API-base override.
    static func allows(_ url: URL, apiBaseOverride: String?) -> Bool {
        if url.scheme?.lowercased() == "https" { return true }
        guard url.scheme?.lowercased() == "http",
              isLoopbackHost(url.host),
              let override = apiBaseOverride,
              let overrideURL = URL(string: override),
              overrideURL.scheme?.lowercased() == "http",
              isLoopbackHost(overrideURL.host) else { return false }
        return true
    }

    static func fetch(url: URL, base: String) async -> Outcome {
        guard allows(url, apiBaseOverride: apiBaseOverride) else {
            return Outcome(data: nil, status: nil, error: "update URL must use HTTPS")
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
        if let token = authToken(base: base) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await UpdateTransport.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return Outcome(data: data, status: status, error: nil)
        } catch {
            return Outcome(data: nil, status: nil, error: error.localizedDescription)
        }
    }
}

/// One session owns every updater request. Its delegate sees redirects before
/// URLSession follows them, allowing arbitrary HTTPS CDNs while refusing any
/// production downgrade to cleartext transport.
final class UpdateTransportDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,
              UpdateFetch.allows(url, apiBaseOverride: UpdateFetch.apiBaseOverride) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum UpdateTransport {
    static let delegate = UpdateTransportDelegate()
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
}

// MARK: - Staging pipeline (nonisolated — download/extract/verify off the main actor)

/// Failure reason wrapper — `Result`'s Failure must be an Error.
struct StageFailure: Error {
    let reason: String
}

/// Pure request ownership for asynchronous staging. Cancellation is only a
/// request, so completions must also match the current generation and version.
struct StagingTracker: Equatable {
    private(set) var generation = 0
    private(set) var version: String?

    mutating func begin(version: String) -> Int {
        generation += 1
        self.version = version
        return generation
    }

    mutating func clear() {
        generation += 1
        version = nil
    }

    func accepts(generation: Int, version: String, availableVersion: String?) -> Bool {
        self.generation == generation && self.version == version && availableVersion == version
    }
}

struct PreparationFailure: Equatable {
    let version: String
    let reason: String
}

struct StagingLimits: Equatable {
    var archiveBytes: Int64
    var extractedBytes: Int64
    var extractionSeconds: TimeInterval
    var pollSeconds: TimeInterval
    var extractedEntries: Int

    static let production = StagingLimits(
        archiveBytes: 100 * 1_000_000,
        extractedBytes: 500 * 1_000_000,
        extractionSeconds: 60,
        pollSeconds: 0.1,
        extractedEntries: 50_000
    )
}

enum MonitoredProcessResult: Equatable {
    case succeeded
    case failed
    case timedOut
    case sizeLimit
    case entryLimit
    case cancelled
}

enum UpdateStaging {
    enum LaunchArtifact: Equatable {
        case staging(UUID)
        case backup(UUID)
    }

    static let staleStagingAge: TimeInterval = 24 * 3600

    /// Only names generated by this updater are artifacts. UUID parsing alone
    /// is permissive, so require UUID's exact uppercase canonical rendering.
    static func launchArtifact(named name: String, bundleName: String = "now.app") -> LaunchArtifact? {
        func canonicalUUID(after prefix: String) -> UUID? {
            guard name.hasPrefix(prefix) else { return nil }
            let raw = String(name.dropFirst(prefix.count))
            guard let uuid = UUID(uuidString: raw), uuid.uuidString == raw else { return nil }
            return uuid
        }
        if let uuid = canonicalUUID(after: ".now-update-") { return .staging(uuid) }
        if let uuid = canonicalUUID(after: "\(bundleName).old-") { return .backup(uuid) }
        return nil
    }

    static func shouldRemoveStaging(path: String, timestamp: Date?, activePaths: [String], now: Date) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !activePaths.contains(standardized),
              let timestamp else { return false }
        return now.timeIntervalSince(timestamp) >= staleStagingAge
    }

    struct StagedUpdate {
        let manifest: UpdateManifest
        let stagingRoot: URL
        let appURL: URL
    }

    /// Sibling staging dir prefix (dot-prefix: LaunchServices never indexes it,
    /// and launch cleanup matches it). Staging is session-scoped: cleaned on
    /// launch, re-created on demand.
    static func stagingRoot(for bundlePath: String) -> URL {
        let dir = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
        return dir.appendingPathComponent(".now-update-\(UUID().uuidString)")
    }

    /// Launch cleanup removes only old staging roots and retries moving valid
    /// rollback bundles to Trash. Active helper-owned paths are excluded.
    static func cleanupLaunchArtifacts(bundlePath: String, now: Date = Date()) {
        let bundleURL = URL(fileURLWithPath: bundlePath)
        let dir = bundleURL.deletingLastPathComponent()
        let name = bundleURL.lastPathComponent // "now.app"
        let environment = ProcessInfo.processInfo.environment
        let activePaths = [environment["NOW_UPDATE_ACTIVE_BACKUP"], environment["NOW_UPDATE_ACTIVE_STAGING"]]
            .compactMap { $0 }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        for entry in entries {
            guard !activePaths.contains(entry.standardizedFileURL.path),
                  let artifact = launchArtifact(named: entry.lastPathComponent, bundleName: name) else { continue }
            switch artifact {
            case .staging:
                let values = try? entry.resourceValues(forKeys: Set(keys))
                let timestamp = values?.contentModificationDate ?? values?.creationDate
                guard shouldRemoveStaging(path: entry.path, timestamp: timestamp, activePaths: activePaths, now: now) else { continue }
                try? FileManager.default.removeItem(at: entry)
            case .backup:
                guard verifySignature(appURL: entry),
                      let info = NSDictionary(contentsOf: entry.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                      info["CFBundleIdentifier"] as? String == UpdateLogic.updateBundleIdentifier else { continue }
                let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
                let destination = trash.appendingPathComponent("now-old-\(UUID().uuidString).app")
                try? FileManager.default.moveItem(at: entry, to: destination)
            }
        }
    }

    /// Full stage: download → extract → contents check → signature gate →
    /// staged-plist sanity. Returns the staged app URL or a reason. The
    /// staging root is deleted by the caller on failure.
    static func stage(manifest: UpdateManifest, bundlePath: String, limits: StagingLimits = .production) async -> Result<StagedUpdate, StageFailure> {
        guard manifest.assetSize <= limits.archiveBytes else {
            return .failure(StageFailure(reason: "update archive larger than \(limits.archiveBytes / 1_000_000) MB"))
        }
        let root = stagingRoot(for: bundlePath)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return .failure(StageFailure(reason: "cannot create staging directory: \(error.localizedDescription)"))
        }
        let failure: (String) -> Result<StagedUpdate, StageFailure> = { reason in
            try? FileManager.default.removeItem(at: root)
            return .failure(StageFailure(reason: reason))
        }
        // 1. Download — HTTPS in production; explicit loopback override in tests.
        guard UpdateFetch.allows(manifest.zipURL, apiBaseOverride: UpdateFetch.apiBaseOverride) else {
            return failure("update URL must be https")
        }
        var request = URLRequest(url: manifest.zipURL)
        request.setValue(UpdateFetch.userAgent(), forHTTPHeaderField: "User-Agent")
        let zipURL = root.appendingPathComponent("now-v\(manifest.version).zip")
        let downloadedBytes: Int64
        do {
            downloadedBytes = try await download(request: request, to: zipURL, maxBytes: limits.archiveBytes)
        } catch let stageFailure as StageFailure {
            return failure(stageFailure.reason)
        } catch {
            return failure("download failed: \(error.localizedDescription)")
        }
        if manifest.assetSize > 0, downloadedBytes != Int64(manifest.assetSize) {
            return failure("download size \(downloadedBytes) ≠ expected \(manifest.assetSize)")
        }
        // 2. Extract with ditto (matches build-app.sh's zip creation flags).
        let extracted = root.appendingPathComponent("extracted")
        do {
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        } catch {
            return failure("cannot create extraction directory")
        }
        let extraction = runMonitoredProcess(
            "/usr/bin/ditto",
            ["-x", "-k", "--sequesterRsrc", zipURL.path, extracted.path],
            monitoredDirectory: extracted,
            limits: limits
        )
        switch extraction {
        case .succeeded:
            break
        case .timedOut:
            return failure("extraction exceeded \(Int(limits.extractionSeconds)) seconds")
        case .sizeLimit:
            return failure("extracted update larger than \(limits.extractedBytes / 1_000_000) MB")
        case .entryLimit:
            return failure("extracted update contains too many files")
        case .cancelled:
            return failure("update preparation cancelled")
        case .failed:
            return failure("extraction failed")
        }
        // 3. Exactly one top-level entry and it is now.app — regardless of
        //    whatever else a malformed or adversarial zip contains.
        guard let entries = try? FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil),
              entries.count == 1,
              entries.first?.lastPathComponent == "now.app",
              entries.first?.hasDirectoryPath == true else {
            return failure("update archive does not contain exactly one now.app")
        }
        let appURL = entries[0]
        // 4. Signature gate: the staged bundle must satisfy a pinned DR.
        guard verifySignature(appURL: appURL) else {
            return failure("update is not signed with a trusted identity")
        }
        // 5. Staged-plist sanity: version match, build not older, OS floor met.
        guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            return failure("staged app has no readable Info.plist")
        }
        let stagedVersion = info["CFBundleShortVersionString"] as? String ?? ""
        guard stagedVersion == manifest.version else {
            return failure("staged version \(stagedVersion) ≠ release version \(manifest.version)")
        }
        let stagedBuild = (info["CFBundleVersion"] as? String).flatMap(Int.init) ?? 0
        guard stagedBuild >= UpdateLogic.currentBuild else {
            return failure("staged build \(stagedBuild) is older than running build \(UpdateLogic.currentBuild)")
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard let required = info["LSMinimumSystemVersion"] as? String,
              UpdateLogic.meetsMinimumSystemVersion(required: required, osMajor: os.majorVersion, osMinor: os.minorVersion, osPatch: os.patchVersion) else {
            let required = info["LSMinimumSystemVersion"] as? String ?? "?"
            return failure("update has invalid or unsupported LSMinimumSystemVersion \(required)")
        }
        return .success(StagedUpdate(manifest: manifest, stagingRoot: root, appURL: appURL))
    }

    /// SecStaticCodeCheckValidity against every pinned requirement. This is
    /// the security gate: a tampered or foreign zip fails here.
    static func verifySignature(appURL: URL) -> Bool {
        let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode else { return false }
        for fingerprint in UpdateLogic.pinnedFingerprints {
            var requirement: SecRequirement?
            let text = UpdateLogic.updateRequirement(fingerprint: fingerprint)
            guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
                  let req = requirement else { continue }
            if SecStaticCodeCheckValidity(code, validationFlags, req) == errSecSuccess { return true }
        }
        return false
    }

    static func download(request: URLRequest, to destination: URL, maxBytes: Int64) async throws -> Int64 {
        guard let url = request.url,
              UpdateFetch.allows(url, apiBaseOverride: UpdateFetch.apiBaseOverride) else {
            throw StageFailure(reason: "update URL must use HTTPS")
        }
        let (bytes, response) = try await UpdateTransport.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StageFailure(reason: "download returned a non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw StageFailure(reason: "download returned \(http.statusCode)")
        }
        if response.expectedContentLength > maxBytes {
            throw StageFailure(reason: "update archive larger than \(maxBytes / 1_000_000) MB")
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw StageFailure(reason: "cannot create staged archive")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: destination)
        } catch {
            throw StageFailure(reason: "cannot write staged archive: \(error.localizedDescription)")
        }
        defer { try? handle.close() }

        var count: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        do {
            for try await byte in bytes {
                try Task.checkCancellation()
                guard count < maxBytes else {
                    throw StageFailure(reason: "update archive larger than \(maxBytes / 1_000_000) MB")
                }
                buffer.append(byte)
                count += 1
                if buffer.count == 64 * 1024 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
            try handle.synchronize()
            return count
        } catch let stageFailure as StageFailure {
            throw stageFailure
        } catch is CancellationError {
            throw StageFailure(reason: "update preparation cancelled")
        } catch {
            throw StageFailure(reason: "download failed: \(error.localizedDescription)")
        }
    }

    static func runMonitoredProcess(_ launchPath: String, _ arguments: [String], monitoredDirectory: URL, limits: StagingLimits) -> MonitoredProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failed
        }

        func stop() {
            if process.isRunning { process.terminate() }
            let grace = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning, ProcessInfo.processInfo.systemUptime < grace {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        let deadline = ProcessInfo.processInfo.systemUptime + limits.extractionSeconds
        while process.isRunning {
            if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) {
                stop()
                return .cancelled
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                stop()
                return .timedOut
            }
            guard let usage = directoryUsage(at: monitoredDirectory, maxEntries: limits.extractedEntries) else {
                stop()
                return .failed
            }
            if usage.entries > limits.extractedEntries {
                stop()
                return .entryLimit
            }
            if usage.bytes > limits.extractedBytes {
                stop()
                return .sizeLimit
            }
            Thread.sleep(forTimeInterval: limits.pollSeconds)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let usage = directoryUsage(at: monitoredDirectory, maxEntries: limits.extractedEntries) else {
            return .failed
        }
        if usage.entries > limits.extractedEntries { return .entryLimit }
        if usage.bytes > limits.extractedBytes { return .sizeLimit }
        return .succeeded
    }

    static func directoryUsage(at directory: URL, maxEntries: Int) -> (bytes: Int64, entries: Int)? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in false }
        ) else { return nil }
        var bytes: Int64 = 0
        var entries = 0
        for case let url as URL in enumerator {
            entries += 1
            if entries > maxEntries { return (bytes, entries) }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let logical = Int64(values.fileSize ?? 0)
            let allocated = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            let (sum, overflow) = bytes.addingReportingOverflow(max(logical, allocated))
            if overflow { return (Int64.max, entries) }
            bytes = sum
        }
        return (bytes, entries)
    }
}

// MARK: - Install helper (detached /bin/sh — the app never swaps itself)

enum UpdateInstaller {
    /// The helper contract (parameters arrive via environment, never
    /// interpolated): wait for the old PID to die (bounded), move old →
    /// backup, staged → app, launch its executable (stripping any stale
    /// NOW_UPDATE_ERROR inherited from an earlier failed install — a
    /// successful retry must never be reported as another failure), wait for
    /// an exact PID/token health acknowledgement, then trash the old bundle.
    /// Every mutation-time failure renames the failed new app aside,
    /// restores a valid bundle, and relaunches the OLD app with
    /// `NOW_UPDATE_ERROR` so it can tell the user; if even that fails, the
    /// browser opens the releases page. Rollback never deletes the app path
    /// before the backup has been restored.
    static let helperScript = """
    PATH=/bin:/usr/bin; export PATH
    end=$(( $(date +%s) + ${NOW_SMOKE_POLL_TIMEOUT:-60} ))
    while kill -0 "$NOW_OLD_PID" 2>/dev/null; do
      if [ "$(date +%s)" -ge "$end" ]; then
        rm -rf "$NOW_STAGING_ROOT"
        [ -n "${NOW_SMOKE_HELPER_DONE:-}" ] && printf timeout > "$NOW_SMOKE_HELPER_DONE"
        exit 1
      fi
      sleep 0.1
    done
    fail() {
      [ -n "${new_pid:-}" ] && kill -0 "$new_pid" 2>/dev/null && kill "$new_pid" 2>/dev/null || true
      if [ -d "$NOW_BACKUP_PATH" ]; then
        if [ -e "$NOW_APP_PATH" ]; then
          mv "$NOW_APP_PATH" "$NOW_FAILED_PATH" || { open "$NOW_RELEASES_URL"; exit 1; }
        fi
        if ! mv "$NOW_BACKUP_PATH" "$NOW_APP_PATH"; then
          [ -e "$NOW_FAILED_PATH" ] && mv "$NOW_FAILED_PATH" "$NOW_APP_PATH" || true
          open "$NOW_RELEASES_URL"
          exit 1
        fi
        rm -rf "$NOW_FAILED_PATH"
      fi
      rm -rf "$NOW_STAGING_ROOT"
      if [ -n "${NOW_SMOKE_FAILURE_REPORT:-}" ]; then
        open --env "NOW_UPDATE_ERROR=$1" --env "NOW_SMOKE_FAILURE_REPORT=$NOW_SMOKE_FAILURE_REPORT" "$NOW_APP_PATH" 2>/dev/null || open "$NOW_RELEASES_URL"
      else
        open --env "NOW_UPDATE_ERROR=$1" "$NOW_APP_PATH" 2>/dev/null || open "$NOW_RELEASES_URL"
      fi
      exit 1
    }
    [ "${NOW_SMOKE_HELPER_FAULT:-}" = "backup" ] && fail "backup move failed"
    mv "$NOW_APP_PATH" "$NOW_BACKUP_PATH" || fail "backup move failed"
    mv "$NOW_STAGED_APP" "$NOW_APP_PATH" || fail "install move failed"
    [ "${NOW_SMOKE_HELPER_FAULT:-}" = "relaunch" ] && fail "relaunch failed"
    env -u NOW_SMOKE_FAILURE_REPORT -u NOW_UPDATE_ERROR "$NOW_APP_PATH/Contents/MacOS/now" >/dev/null 2>&1 &
    new_pid=$!
    health_end=$(( $(date +%s) + ${NOW_SMOKE_HEALTH_TIMEOUT:-30} ))
    while :; do
      health="$(cat "$NOW_HEALTH_ACK" 2>/dev/null || true)"
      [ "$health" = "$new_pid:$NOW_HEALTH_TOKEN" ] && break
      kill -0 "$new_pid" 2>/dev/null || fail "updated app exited before startup health check"
      [ "$(date +%s)" -ge "$health_end" ] && fail "updated app startup health check timed out"
      sleep 0.1
    done
    rm -rf "$NOW_STAGING_ROOT"
    mv "$NOW_BACKUP_PATH" "$HOME/.Trash/now-old-$(date +%Y%m%d%H%M%S)-$$.app" 2>/dev/null
    [ -n "${NOW_SMOKE_HELPER_DONE:-}" ] && printf done > "$NOW_SMOKE_HELPER_DONE"
    exit 0
    """

    /// Any other live instance with our bundle id blocks the update —
    /// different-path copies AND `open -n` same-path seconds (which would
    /// keep the old binary mapped through the swap). CLI runs (`--parse`
    /// etc.) never register with LaunchServices and don't count.
    @MainActor
    static func otherInstanceRunning() -> Bool {
        let pid = getpid()
        let bundleID = Bundle.main.bundleIdentifier ?? UpdateLogic.updateBundleIdentifier
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != pid
        }
    }

    /// Spawns the detached helper. Smoke variables are stripped from the
    /// inherited environment and only an explicit hidden-CLI allow-list can
    /// add them back through `extraEnv`.
    /// The environment INHERITS the app's (the helper needs the real $HOME
    /// for `~/.Trash` — replacing it wholesale once silently skipped the
    /// trash step) with overrides applied on top.
    @MainActor
    static func spawnHelper(bundlePath: String, stagedAppPath: String, backupPath: String, releasesURL: String, extraEnv: [String: String] = [:]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", helperScript]
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys.filter({ $0.hasPrefix("NOW_SMOKE_") }) {
            environment.removeValue(forKey: key)
        }
        let allowedSmokeKeys: Set<String> = [
            "NOW_SMOKE_REPORT", "NOW_SMOKE_FAILURE_REPORT", "NOW_SMOKE_POLL_TIMEOUT",
            "NOW_SMOKE_HEALTH_TIMEOUT", "NOW_SMOKE_HELPER_FAULT", "NOW_SMOKE_HELPER_DONE"
        ]
        for (key, value) in extraEnv where allowedSmokeKeys.contains(key) {
            environment[key] = value
        }
        environment["NOW_OLD_PID"] = String(getpid())
        environment["NOW_APP_PATH"] = bundlePath
        environment["NOW_STAGED_APP"] = stagedAppPath
        let stagingRoot = URL(fileURLWithPath: stagedAppPath).deletingLastPathComponent().deletingLastPathComponent().path
        environment["NOW_STAGING_ROOT"] = stagingRoot
        environment["NOW_BACKUP_PATH"] = backupPath
        environment["NOW_FAILED_PATH"] = backupPath + ".failed"
        environment["NOW_HEALTH_TOKEN"] = UUID().uuidString
        environment["NOW_HEALTH_ACK"] = stagingRoot + "/health-ack"
        environment["NOW_UPDATE_ACTIVE_BACKUP"] = backupPath
        environment["NOW_UPDATE_ACTIVE_STAGING"] = stagingRoot
        environment["NOW_RELEASES_URL"] = releasesURL
        if let home = extraEnv["NOW_SMOKE_HOME"] { environment["HOME"] = home }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Controller (MainActor)

/// What the update window shows. One window class, four content shapes.
enum UpdateWindowContent: Equatable {
    case available(UpdateManifest)
    case upToDate
    /// The helper relaunched us as a freshly installed version — one-time
    /// confirmation that the update worked.
    case installed(version: String)
    /// Any refusal/failure: fetch error (retryable), install guard refusal,
    /// or the NOW_UPDATE_ERROR relaunch path.
    case problem(title: String, message: String, retry: UpdateRetry?)
}

enum UpdateRetry: Equatable {
    case check
    case preparation
}

@MainActor
final class UpdateController: ObservableObject {
    nonisolated static let stateKey = "local.tboch.now.updates.v1"
    /// Automatic checks ignore releases younger than this (manual bypasses) —
    /// the maintainer's window to delete a bad release before it spreads.
    nonisolated static let ageGate: TimeInterval = 24 * 3600

    @Published private(set) var available: UpdateManifest?
    /// Version whose bundle is downloaded + verified and ready to install.
    @Published private(set) var stagedVersion: String?
    @Published private(set) var isChecking = false
    @Published private(set) var lastSuccessfulCheck: Date?
    @Published private(set) var lastCheckError: String?
    @Published private(set) var preparationFailure: PreparationFailure?
    /// Non-nil ⇒ the update window should be (or is being) shown.
    @Published var windowContent: UpdateWindowContent? {
        didSet {
            if windowContent != nil { onWindowRequest?() }
        }
    }

    unowned let store: AppStore
    /// AppDelegate hooks: show (and defer while a reminder shows) the window,
    /// and terminate without the quit confirmations for the install.
    var onWindowRequest: (() -> Void)?
    var onTerminateForUpdate: (() -> Void)?

    /// Detected at launch when the running version equals the pending-install
    /// marker; consumed (and confirmed to the user) only after the startup
    /// health acknowledgement — the install's commit point.
    private(set) var pendingInstalledVersion: String?
    private(set) var state = UpdateState()
    private var stagedRoot: URL?
    private var checkTimer: Timer?
    private var stagingTask: Task<Void, Never>?
    private var stagingTracker = StagingTracker()
    private var started = false

    init(store: AppStore) {
        self.store = store
        if let data = UserDefaults.standard.data(forKey: Self.stateKey),
           let decoded = try? JSONDecoder().decode(UpdateState.self, from: data) {
            state = decoded
        }
        lastSuccessfulCheck = state.lastSuccessCheckDate
    }

    deinit {
        checkTimer?.invalidate()
    }

    func start() {
        guard !started else { return }
        started = true
        // A successful install relaunches us AS the pending version — DETECT
        // the marker now, but consume it only once startup has been health-
        // acknowledged (`startupHealthAcknowledged`, +2 s): until then the
        // install helper can still roll back to the old version, and the
        // surviving marker is exactly what lets that rolled-back app suppress
        // re-offering the failed version. (The failed-install relaunch runs
        // the OLD app with NOW_UPDATE_ERROR and shows the problem window —
        // the two paths never overlap.)
        pendingInstalledVersion = UpdateLogic.justInstalledVersion(pending: state.pendingInstallVersion, currentVersion: UpdateLogic.currentVersion)
        UpdateStaging.cleanupLaunchArtifacts(bundlePath: Bundle.main.bundlePath)
        // Launch +10 s: past the startup burst, before the user leaves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.checkMaybeAutomatic()
        }
        // .common mode like every app timer (menus/modals must not stall it).
        checkTimer = AppStore.commonTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMaybeAutomatic() }
        }
    }

    /// The GUI app just wrote its startup health acknowledgement — the
    /// install transaction's commit point. Only now is a pending-install
    /// marker proof of success: consume it and confirm to the user. (Called
    /// from AppDelegate right after `NowApp.acknowledgeUpdatedStartup()`;
    /// before this, the helper may still roll back and relaunch the OLD app,
    /// where the marker must survive so the failed version isn't re-offered.)
    func startupHealthAcknowledged() {
        pendingInstalledVersion = nil
        guard let installed = UpdateLogic.justInstalledVersion(pending: state.pendingInstallVersion, currentVersion: UpdateLogic.currentVersion) else { return }
        state = UpdateLogic.stateAfterSuccessfulInstall(state)
        saveState()
        windowContent = .installed(version: installed)
    }

    /// Automatic trigger (launch timer / 24 h timer / wake) — honors the
    /// settings toggle and the throttle. Also called by AppDelegate's wake
    /// observer.
    func checkMaybeAutomatic() {
        guard store.settings.automaticUpdateChecks else { return }
        check(userInitiated: false)
    }
    func check(userInitiated: Bool) {
        guard !isChecking else { return }
        // A check while the update window is open is a no-op (any variant).
        guard windowContent == nil else { return }
        guard userInitiated || UpdateLogic.shouldAutoCheck(state: state, now: Date()) else { return }
        isChecking = true
        lastCheckError = nil
        let base = UpdateFetch.resolvedBase(nil)
        let repo = UpdateFetch.resolvedRepo(nil)
        guard let url = UpdateFetch.latestReleaseURL(base: base, repo: repo) else {
            isChecking = false
            recordAttempt(success: false, now: Date())
            lastCheckError = "invalid update URL"
            if userInitiated { windowContent = .problem(title: "Couldn't check for updates", message: "Invalid update URL.", retry: .check) }
            return
        }
        Task { [weak self] in
            let outcome = await UpdateFetch.fetch(url: url, base: base)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.finishCheck(outcome: outcome, userInitiated: userInitiated)
            }
        }
    }

    private func finishCheck(outcome: UpdateFetch.Outcome, userInitiated: Bool) {
        isChecking = false
        let now = Date()
        // 404 = no releases at all → silently up to date.
        if let status = outcome.status, status == 404 {
            recordAttempt(success: true, now: now)
            applyDecision(.upToDate, userInitiated: userInitiated)
            return
        }
        if let error = outcome.error {
            recordAttempt(success: false, now: now)
            lastCheckError = error
            if userInitiated { windowContent = .problem(title: "Couldn't check for updates", message: error, retry: .check) }
            return
        }
        guard UpdateFetch.isSuccessfulStatus(outcome.status) else {
            let reason = outcome.status.map({ "server returned \($0)" }) ?? "invalid server response"
            recordAttempt(success: false, now: now)
            lastCheckError = reason
            if userInitiated { windowContent = .problem(title: "Couldn't check for updates", message: reason, retry: .check) }
            return
        }
        guard let data = outcome.data, let manifest = UpdateLogic.parseLatestRelease(data) else {
            let reason = outcome.status.map({ "server returned \($0)" }) ?? "unreadable response"
            recordAttempt(success: false, now: now)
            lastCheckError = reason
            if userInitiated { windowContent = .problem(title: "Couldn't check for updates", message: reason, retry: .check) }
            return
        }
        recordAttempt(success: true, now: now)
        let decision = UpdateLogic.decide(
            manifest: manifest,
            currentVersion: UpdateLogic.currentVersion,
            skipped: store.settings.skippedUpdateVersion,
            now: now,
            minAge: userInitiated ? 0 : Self.ageGate
        )
        applyDecision(decision, userInitiated: userInitiated)
    }

    private func applyDecision(_ decision: UpdateDecision, userInitiated: Bool) {
        switch decision {
        case .available(let manifest):
            available = manifest
            noteFirstSeen(manifest)
            // First discovery stages eagerly. Once a shown update loses its
            // session staging, later automatic checks keep the offer visible
            // without downloading again; manual checks/actions are explicit.
            let shouldStage = UpdateLogic.shouldStageUpdate(version: manifest.version, userInitiated: userInitiated, state: state)
            if shouldStage, stagedVersion != manifest.version, stagingTracker.version != manifest.version {
                beginStaging(manifest)
            }
            if userInitiated {
                presentAvailable(manifest)
            } else if stagedVersion == manifest.version,
                      UpdateLogic.shouldEscalate(availableVersion: manifest.version, state: state, now: Date()) {
                presentAvailable(manifest)
            }
        case .skippedVersion:
            break // v2 UI; silently equals up-to-date for now
        case .upToDate:
            available = nil
            clearStaging()
            state.firstSeenUpdateVersion = nil
            state.firstSeenUpdateDate = nil
            saveState()
            if userInitiated { windowContent = .upToDate }
        case .error(let reason):
            lastCheckError = reason
            if userInitiated {
                windowContent = .problem(title: "Couldn't check for updates", message: reason, retry: .check)
            }
        }
    }

    private func noteFirstSeen(_ manifest: UpdateManifest) {
        guard state.firstSeenUpdateVersion != manifest.version else { return }
        state.firstSeenUpdateVersion = manifest.version
        state.firstSeenUpdateDate = Date()
        saveState()
    }

    /// Requests the available window. AppDelegate records notification only
    /// after the request is actually visible (a reminder can defer it).
    private func presentAvailable(_ manifest: UpdateManifest) {
        windowContent = .available(manifest)
    }

    func updateWindowDidShow() {
        let shownVersion: String?
        switch windowContent {
        case .available(let manifest):
            shownVersion = manifest.version
        case .problem(_, _, .preparation):
            shownVersion = available?.version
        default:
            shownVersion = nil
        }
        guard let shownVersion, state.lastNotifiedVersion != shownVersion else { return }
        state = UpdateLogic.stateAfterShowingUpdate(state, version: shownVersion)
        saveState()
    }

    /// Menu "Update to v1.5.0…" / Settings "Install…": open the window for
    /// the known-available update without re-checking.
    func presentAvailableFromMenu() {
        if let manifest = available {
            if let failure = preparationFailure, failure.version == manifest.version {
                windowContent = .problem(title: "Couldn't prepare the update", message: failure.reason, retry: .preparation)
            } else {
                if stagedVersion != manifest.version, stagingTracker.version != manifest.version {
                    beginStaging(manifest)
                }
                presentAvailable(manifest)
            }
        }
    }

    func dismissWindow() {
        windowContent = nil
    }

    /// "Try Again": dismiss the problem window, then re-check (the check
    /// guards against an open window, so order matters).
    func retry(_ retry: UpdateRetry) {
        windowContent = nil
        switch retry {
        case .check:
            check(userInitiated: true)
        case .preparation:
            retryPreparation()
        }
    }

    /// ⌘W / window close — mirrors dismissWindow without re-triggering close.
    func windowClosedExternally() {
        if windowContent != nil { windowContent = nil }
    }

    // MARK: Staging

    private func beginStaging(_ manifest: UpdateManifest) {
        clearStaging()
        preparationFailure = nil
        let generation = stagingTracker.begin(version: manifest.version)
        stagingTask = Task { [weak self] in
            let result = await UpdateStaging.stage(manifest: manifest, bundlePath: Bundle.main.bundlePath)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.stagingTracker.accepts(generation: generation, version: manifest.version, availableVersion: self.available?.version) else {
                    if case .success(let stale) = result {
                        try? FileManager.default.removeItem(at: stale.stagingRoot)
                    }
                    return
                }
                self.stagingTask = nil
                self.stagingTracker.clear()
                switch result {
                case .success(let staged):
                    self.stagedRoot = staged.stagingRoot
                    self.stagedVersion = staged.manifest.version
                    // Escalation is evaluated once staging is ready.
                    if self.available?.version == staged.manifest.version,
                       UpdateLogic.shouldEscalate(availableVersion: staged.manifest.version, state: self.state, now: Date()) {
                        self.presentAvailable(staged.manifest)
                    }
                case .failure(let stageFailure):
                    self.lastCheckError = stageFailure.reason
                    self.preparationFailure = PreparationFailure(version: manifest.version, reason: stageFailure.reason)
                    if case .available(let shown) = self.windowContent, shown.version == manifest.version {
                        self.windowContent = .problem(title: "Couldn't prepare the update", message: stageFailure.reason, retry: .preparation)
                    }
                }
            }
        }
    }

    func retryPreparation() {
        guard let manifest = available else { return }
        beginStaging(manifest)
        presentAvailable(manifest)
    }

    private func clearStaging() {
        stagingTask?.cancel()
        stagingTask = nil
        stagingTracker.clear()
        if let stagedRoot {
            try? FileManager.default.removeItem(at: stagedRoot)
        }
        stagedRoot = nil
        stagedVersion = nil
        preparationFailure = nil
    }

    // MARK: Install

    func install() {
        guard let manifest = available else {
            windowContent = .problem(title: "No update staged", message: "Check for updates first.", retry: .check)
            return
        }
        guard stagedVersion == manifest.version, let stagedRoot else {
            windowContent = .problem(title: "Update is still downloading", message: "Try again in a moment — the update is being prepared.", retry: .preparation)
            return
        }
        if let problem = UpdateLogic.installLocationProblem(Bundle.main.bundlePath) {
            windowContent = .problem(title: "Can't update in place", message: problem, retry: nil)
            return
        }
        guard !UpdateInstaller.otherInstanceRunning() else {
            windowContent = .problem(title: "Another copy of now is running", message: "Quit the other copy of now, then update again.", retry: nil)
            return
        }
        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        let backupPath = bundleURL.deletingLastPathComponent()
            .appendingPathComponent("now.app.old-\(UUID().uuidString)").path
        state.pendingInstallVersion = manifest.version
        saveState()
        guard UpdateInstaller.spawnHelper(
            bundlePath: Bundle.main.bundlePath,
            stagedAppPath: stagedRoot.appendingPathComponent("extracted/now.app").path,
            backupPath: backupPath,
            releasesURL: Links.releases.absoluteString,
            extraEnv: [:]
        ) else {
            state.pendingInstallVersion = nil
            saveState()
            windowContent = .problem(title: "Couldn't start the updater", message: "The update helper failed to launch. Download the update manually.", retry: nil)
            return
        }
        onTerminateForUpdate?()
    }

    /// The helper relaunched us after a FAILED update — show what happened
    /// and never auto-offer that version again on this install.
    func handleInstallFailure(reason: String) {
        state = UpdateLogic.stateAfterInstallFailure(state)
        saveState()
        windowContent = .problem(title: "Update failed", message: reason + " The previous version is still running. You can also download the update manually.", retry: nil)
    }

    // MARK: State

    private func recordAttempt(success: Bool, now: Date) {
        let stamp = UpdateLogic.dayStamp(now)
        if state.attemptsDayStamp != stamp {
            state.attemptsDayStamp = stamp
            state.attemptsToday = 0
        }
        state.lastAttemptDate = now
        if success {
            state.lastSuccessCheckDate = now
            state.attemptsToday = 0
            lastSuccessfulCheck = now
        } else {
            state.attemptsToday += 1
        }
        saveState()
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
    }
}
