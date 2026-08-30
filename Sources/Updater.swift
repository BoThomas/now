import Foundation
import AppKit
import Security

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

    /// STRICT variant: every dot-component must be a plain integer (no
    /// "1.5.0-beta.1", no dropped junk) — lenient `compactMap` parsing made
    /// prerelease tags masquerade as valid versions.
    static func strictVersionComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }
        var result: [Int] = []
        for part in parts {
            guard let value = Int(part), part == String(value) else { return nil }
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
        guard let required else { return true }
        let parts = versionComponents(required)
        guard !parts.isEmpty else { return true }
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
    static func parseLatestRelease(_ data: Data, appName: String = "now") -> UpdateManifest? {
        guard let release = try? JSONDecoder().decode(GitHubLatestRelease.self, from: data) else { return nil }
        guard let version = version(fromTag: release.tag_name) else { return nil }
        let assetName = "\(appName)-v\(version).zip"
        guard let asset = release.assets.first(where: { $0.name == assetName }) else { return nil }
        guard let url = URL(string: asset.browser_download_url) else { return nil }
        let published: Date
        if let iso = release.published_at, let parsed = ISO8601DateFormatter().date(from: iso) {
            published = parsed
        } else {
            published = Date()
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

    static func fetch(url: URL, base: String) async -> Outcome {
        var request = URLRequest(url: url)
        request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
        if let token = authToken(base: base) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await AppStore.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return Outcome(data: data, status: status, error: nil)
        } catch {
            return Outcome(data: nil, status: nil, error: error.localizedDescription)
        }
    }
}

// MARK: - Staging pipeline (nonisolated — download/extract/verify off the main actor)

/// Failure reason wrapper — `Result`'s Failure must be an Error.
struct StageFailure: Error {
    let reason: String
}

enum UpdateStaging {
    struct StagedUpdate {
        let manifest: UpdateManifest
        let stagingRoot: URL
        let appURL: URL
    }

    /// Hard cap on the update archive — matches the plan's 100 MB budget.
    static let maxArchiveBytes = 100 * 1_000_000

    /// Sibling staging dir prefix (dot-prefix: LaunchServices never indexes it,
    /// and launch cleanup matches it). Staging is session-scoped: cleaned on
    /// launch, re-created on demand.
    static func stagingRoot(for bundlePath: String) -> URL {
        let dir = URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
        return dir.appendingPathComponent(".now-update-\(UUID().uuidString)")
    }

    /// Launch cleanup: drop stale staging dirs and leftover rollback backups
    /// (a `now.app.old-*` only ever exists after a successful swap, so
    /// removing it is safe).
    static func cleanupLaunchArtifacts(bundlePath: String) {
        let bundleURL = URL(fileURLWithPath: bundlePath)
        let dir = bundleURL.deletingLastPathComponent()
        let name = bundleURL.lastPathComponent // "now.app"
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let entryName = entry.lastPathComponent
            if entryName.hasPrefix(".now-update-") || entryName.hasPrefix("\(name).old-") {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    /// Full stage: download → extract → contents check → signature gate →
    /// staged-plist sanity. Returns the staged app URL or a reason. The
    /// staging root is deleted by the caller on failure.
    static func stage(manifest: UpdateManifest, bundlePath: String) async -> Result<StagedUpdate, StageFailure> {
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
        // 1. Download — https only, except explicit localhost for the smoke test.
        guard let scheme = manifest.zipURL.scheme?.lowercased(),
              scheme == "https" || manifest.zipURL.host == "127.0.0.1" || manifest.zipURL.host == "localhost" else {
            return failure("update URL must be https")
        }
        var request = URLRequest(url: manifest.zipURL)
        request.setValue(UpdateFetch.userAgent(), forHTTPHeaderField: "User-Agent")
        let data: Data
        do {
            let (body, response) = try await AppStore.session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return failure("download returned \(http.statusCode)")
            }
            data = body
        } catch {
            return failure("download failed: \(error.localizedDescription)")
        }
        if data.count > maxArchiveBytes { return failure("update archive larger than \(maxArchiveBytes / 1_000_000) MB") }
        if manifest.assetSize > 0, data.count != manifest.assetSize {
            return failure("download size \(data.count) ≠ expected \(manifest.assetSize)")
        }
        let zipURL = root.appendingPathComponent("now-v\(manifest.version).zip")
        do {
            try data.write(to: zipURL)
        } catch {
            return failure("cannot write staged archive: \(error.localizedDescription)")
        }
        // 2. Extract with ditto (matches build-app.sh's zip creation flags).
        let extracted = root.appendingPathComponent("extracted")
        do {
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        } catch {
            return failure("cannot create extraction directory")
        }
        guard runProcess("/usr/bin/ditto", ["-x", "-k", "--sequesterRsrc", zipURL.path, extracted.path]) else {
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
        guard UpdateLogic.meetsMinimumSystemVersion(required: info["LSMinimumSystemVersion"] as? String, osMajor: os.majorVersion, osMinor: os.minorVersion, osPatch: os.patchVersion) else {
            let required = info["LSMinimumSystemVersion"] as? String ?? "?"
            return failure("update requires macOS \(required) or newer")
        }
        return .success(StagedUpdate(manifest: manifest, stagingRoot: root, appURL: appURL))
    }

    /// SecStaticCodeCheckValidity against every pinned requirement. This is
    /// the security gate: a tampered or foreign zip fails here.
    static func verifySignature(appURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode else { return false }
        for fingerprint in UpdateLogic.pinnedFingerprints {
            var requirement: SecRequirement?
            let text = UpdateLogic.updateRequirement(fingerprint: fingerprint)
            guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
                  let req = requirement else { continue }
            if SecStaticCodeCheckValidity(code, SecCSFlags(), req) == errSecSuccess { return true }
        }
        return false
    }

    @discardableResult
    static func runProcess(_ launchPath: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// MARK: - Install helper (detached /bin/sh — the app never swaps itself)

enum UpdateInstaller {
    /// The helper contract (parameters arrive via environment, never
    /// interpolated): wait for the old PID to die (bounded), move old →
    /// backup, staged → app, relaunch, trash the old bundle. Every failure
    /// path restores a valid bundle first and relaunches the OLD app with
    /// `NOW_UPDATE_ERROR` so it can tell the user; if even that fails, the
    /// browser opens the releases page. `mv` cannot replace an existing app
    /// directory — hence the `rm -rf` before restore in fail().
    static let helperScript = """
    PATH=/bin:/usr/bin; export PATH
    end=$(( $(date +%s) + ${NOW_SMOKE_POLL_TIMEOUT:-60} ))
    while kill -0 "$NOW_OLD_PID" 2>/dev/null; do
      [ "$(date +%s)" -ge "$end" ] && exit 1
      sleep 0.1
    done
    fail() {
      if [ -d "$NOW_BACKUP_PATH" ]; then
        rm -rf "$NOW_APP_PATH"
        mv "$NOW_BACKUP_PATH" "$NOW_APP_PATH" || true
      fi
      open --env "NOW_UPDATE_ERROR=$1" "$NOW_APP_PATH" 2>/dev/null || open "$NOW_RELEASES_URL"
      exit 1
    }
    mv "$NOW_APP_PATH" "$NOW_BACKUP_PATH"
    mv "$NOW_STAGED_APP" "$NOW_APP_PATH" || fail "install move failed"
    if [ -n "${NOW_SMOKE_REPORT:-}" ]; then
      open --env "NOW_SMOKE_REPORT=$NOW_SMOKE_REPORT" "$NOW_APP_PATH" || fail "relaunch failed"
    else
      open "$NOW_APP_PATH" || fail "relaunch failed"
    fi
    mv "$NOW_BACKUP_PATH" "$HOME/.Trash/now-old-$(date +%Y%m%d%H%M%S).app" 2>/dev/null
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

    /// Spawns the detached helper. `extraEnv` carries smoke-test overrides
    /// (NOW_SMOKE_REPORT / NOW_SMOKE_POLL_TIMEOUT) and the sandboxed HOME.
    /// The environment INHERITS the app's (the helper needs the real $HOME
    /// for `~/.Trash` — replacing it wholesale once silently skipped the
    /// trash step) with overrides applied on top.
    @MainActor
    static func spawnHelper(bundlePath: String, stagedAppPath: String, backupPath: String, releasesURL: String, extraEnv: [String: String] = [:]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", helperScript]
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in extraEnv where key != "NOW_SMOKE_HOME" {
            environment[key] = value
        }
        environment["NOW_OLD_PID"] = String(getpid())
        environment["NOW_APP_PATH"] = bundlePath
        environment["NOW_STAGED_APP"] = stagedAppPath
        environment["NOW_BACKUP_PATH"] = backupPath
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

/// What the update window shows. One window class, three content shapes.
enum UpdateWindowContent: Equatable {
    case available(UpdateManifest)
    case upToDate
    /// Any refusal/failure: fetch error (retryable), install guard refusal,
    /// or the NOW_UPDATE_ERROR relaunch path.
    case problem(title: String, message: String, retry: Bool)
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

    private(set) var state = UpdateState()
    private var stagedRoot: URL?
    private var checkTimer: Timer?
    private var stagingTask: Task<Void, Never>?
    private var wakeObserver: Any?
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
        if let wakeObserver { NotificationCenter.default.removeObserver(wakeObserver) }
    }

    func start() {
        guard !started else { return }
        started = true
        // A successful install relaunches us AS the pending version — clear
        // the marker so a later failed update can't mark the wrong version
        // as already-notified.
        if state.pendingInstallVersion == UpdateLogic.currentVersion {
            state.pendingInstallVersion = nil
            saveState()
        }
        UpdateStaging.cleanupLaunchArtifacts(bundlePath: Bundle.main.bundlePath)
        // Launch +10 s: past the startup burst, before the user leaves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.checkMaybeAutomatic()
        }
        // .common mode like every app timer (menus/modals must not stall it).
        checkTimer = AppStore.commonTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMaybeAutomatic() }
        }
        wakeObserver = NotificationCenter.default.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMaybeAutomatic() }
        }
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
            if userInitiated { windowContent = .problem(title: "Couldn't check for updates", message: "Invalid update URL.", retry: true) }
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
            if userInitiated { windowContent = .problem(title: "Couldn't check for updates", message: error, retry: true) }
            return
        }
        guard let data = outcome.data, let manifest = UpdateLogic.parseLatestRelease(data) else {
            let reason = outcome.status.map({ "server returned \($0)" }) ?? "unreadable response"
            recordAttempt(success: false, now: now)
            lastCheckError = reason
            if userInitiated { windowContent = .problem(title: "Couldn't check for updates", message: reason, retry: true) }
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
            // Decide-before-download is honored by never staging when the
            // discovery is already notified/skipped — but an *offered*
            // version stages eagerly so Install is instant.
            if stagedVersion != manifest.version, stagingTask == nil {
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
                windowContent = .problem(title: "Couldn't check for updates", message: reason, retry: true)
            }
        }
    }

    private func noteFirstSeen(_ manifest: UpdateManifest) {
        guard state.firstSeenUpdateVersion != manifest.version else { return }
        state.firstSeenUpdateVersion = manifest.version
        state.firstSeenUpdateDate = Date()
        saveState()
    }

    /// Sets window content + records show-time notification bookkeeping.
    /// `lastNotifiedVersion` is written HERE (never when a check lands), so a
    /// deferred window can't suppress itself and a shown version never nags
    /// again automatically.
    private func presentAvailable(_ manifest: UpdateManifest) {
        state.lastNotifiedVersion = manifest.version
        saveState()
        windowContent = .available(manifest)
    }

    /// Menu "Update to v1.5.0…" / Settings "Install…": open the window for
    /// the known-available update without re-checking.
    func presentAvailableFromMenu() {
        if let manifest = available {
            presentAvailable(manifest)
        }
    }

    func dismissWindow() {
        windowContent = nil
    }

    /// "Try Again": dismiss the problem window, then re-check (the check
    /// guards against an open window, so order matters).
    func retryCheck() {
        windowContent = nil
        check(userInitiated: true)
    }

    /// ⌘W / window close — mirrors dismissWindow without re-triggering close.
    func windowClosedExternally() {
        if windowContent != nil { windowContent = nil }
    }

    // MARK: Staging

    private func beginStaging(_ manifest: UpdateManifest) {
        clearStaging()
        stagingTask = Task { [weak self] in
            let result = await UpdateStaging.stage(manifest: manifest, bundlePath: Bundle.main.bundlePath)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.stagingTask = nil
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
                    // Only surface staging failures for the manual flow (an
                    // auto-check that can't stage stays quiet and retries).
                    if case .available(let shown) = self.windowContent, shown.version == manifest.version {
                        self.windowContent = .problem(title: "Couldn't prepare the update", message: stageFailure.reason, retry: true)
                    }
                }
            }
        }
    }

    private func clearStaging() {
        stagingTask?.cancel()
        stagingTask = nil
        if let stagedRoot {
            try? FileManager.default.removeItem(at: stagedRoot)
        }
        stagedRoot = nil
        stagedVersion = nil
    }

    // MARK: Install

    func install() {
        guard let manifest = available else {
            windowContent = .problem(title: "No update staged", message: "Check for updates first.", retry: true)
            return
        }
        guard stagedVersion == manifest.version, let stagedRoot else {
            windowContent = .problem(title: "Update is still downloading", message: "Try again in a moment — the update is being prepared.", retry: true)
            return
        }
        if let problem = UpdateLogic.installLocationProblem(Bundle.main.bundlePath) {
            windowContent = .problem(title: "Can't update in place", message: problem, retry: false)
            return
        }
        guard !UpdateInstaller.otherInstanceRunning() else {
            windowContent = .problem(title: "Another copy of now is running", message: "Quit the other copy of now, then update again.", retry: false)
            return
        }
        let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
        let backupPath = bundleURL.deletingLastPathComponent()
            .appendingPathComponent("now.app.old-\(UUID().uuidString)").path
        state.pendingInstallVersion = manifest.version
        saveState()
        var extraEnv: [String: String] = [:]
        let env = ProcessInfo.processInfo.environment
        if let report = env["NOW_SMOKE_REPORT"] { extraEnv["NOW_SMOKE_REPORT"] = report }
        if let home = env["NOW_SMOKE_HOME"] { extraEnv["NOW_SMOKE_HOME"] = home }
        if let timeout = env["NOW_SMOKE_POLL_TIMEOUT"] { extraEnv["NOW_SMOKE_POLL_TIMEOUT"] = timeout }
        guard UpdateInstaller.spawnHelper(
            bundlePath: Bundle.main.bundlePath,
            stagedAppPath: stagedRoot.appendingPathComponent("extracted/now.app").path,
            backupPath: backupPath,
            releasesURL: Links.releases.absoluteString,
            extraEnv: extraEnv
        ) else {
            state.pendingInstallVersion = nil
            saveState()
            windowContent = .problem(title: "Couldn't start the updater", message: "The update helper failed to launch. Download the update manually.", retry: false)
            return
        }
        onTerminateForUpdate?()
    }

    /// The helper relaunched us after a FAILED update — show what happened
    /// and never auto-offer that version again on this install.
    func handleInstallFailure(reason: String) {
        if let pending = state.pendingInstallVersion {
            state.lastNotifiedVersion = pending
        }
        state.pendingInstallVersion = nil
        saveState()
        windowContent = .problem(title: "Update failed", message: reason + " The previous version is still running. You can also download the update manually.", retry: false)
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
