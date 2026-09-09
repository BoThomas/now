import Foundation
import CryptoKit

/// A materialized feed snapshot, never a source of new recurrence expansion.
/// Presentation fields and muted state are always taken from the live subscription.
struct CachedMeeting: Codable {
    let uid: String
    let notificationIdentity: String?
    let title: String
    let start: Date
    let end: Date
    let location: String?
    let notes: String?
    let link: URL?

    init(_ event: MeetingEvent) {
        notificationIdentity = event.notificationIdentity
        uid = event.uid; title = event.title; start = event.start; end = event.end
        location = event.location; notes = event.notes; link = event.link
    }

    func event(subscription: CalendarSubscription) -> MeetingEvent {
        MeetingEvent(uid: uid, title: title, start: start, end: end, location: location,
                     notes: notes, link: link, calendarID: subscription.id,
                     calendarName: subscription.name, colorIndex: subscription.colorIndex,
                     colorHex: subscription.colorHex, notificationIdentity: notificationIdentity)
    }

    var estimatedBytes: Int {
        // JSON escaping can expand each byte sixfold. Bound encoding allocations too.
        256 + [uid, notificationIdentity ?? "", title, location ?? "", notes ?? "", link?.absoluteString ?? ""].reduce(0) { $0 + $1.utf8.count * 6 }
    }
}

struct CalendarCacheSnapshot: Codable {
    static let version = 1
    var version = Self.version
    let calendarID: UUID
    let sourceFingerprint: String
    let fetchedAt: Date
    let coverageStart: Date
    let coverageEnd: Date
    let warning: String?
    let meetings: [CachedMeeting]

    init(subscription: CalendarSubscription, events: [MeetingEvent], fetchedAt: Date, warning: String?) {
        calendarID = subscription.id
        sourceFingerprint = Self.fingerprint(subscription.url)
        self.fetchedAt = fetchedAt
        coverageStart = fetchedAt.addingTimeInterval(-6 * 3600)
        coverageEnd = fetchedAt.addingTimeInterval(14 * 86400)
        self.warning = warning
        meetings = events.map(CachedMeeting.init)
    }

    static func fingerprint(_ url: String) -> String {
        SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func matches(_ subscription: CalendarSubscription) -> Bool {
        subscription.isEnabled && calendarID == subscription.id && sourceFingerprint == Self.fingerprint(subscription.url)
    }

    var isValid: Bool {
        version == Self.version && (0..<253_402_300_800).contains(fetchedAt.timeIntervalSince1970) &&
        coverageStart == fetchedAt.addingTimeInterval(-6 * 3600) &&
        coverageEnd == fetchedAt.addingTimeInterval(14 * 86400) &&
        meetings.count <= 10_000 && meetings.allSatisfy {
            $0.start.timeIntervalSince1970.isFinite && (0..<1_000_000_000_000).contains($0.end.timeIntervalSince1970) &&
            $0.start >= coverageStart && $0.start <= coverageEnd && $0.end > $0.start &&
            ($0.link == nil || ["http", "https"].contains($0.link?.scheme?.lowercased() ?? ""))
        }
    }

    func events(subscription: CalendarSubscription, now: Date) -> [MeetingEvent] {
        guard isValid, matches(subscription), now >= coverageStart, now <= coverageEnd else { return [] }
        return meetings.filter { $0.end > now }.map { $0.event(subscription: subscription) }
    }
}

struct CalendarCacheLoad {
    var snapshots: [UUID: CalendarCacheSnapshot] = [:]
    var issues: [UUID: String] = [:]
}

/// All filesystem work is serialized off the main actor. Calls enqueue immediately,
/// preserving save/remove order even when a source is edited while a write runs.
final class CalendarEventCache: @unchecked Sendable {
    static let maxSnapshotBytes = 16 * 1_000_000
    static let maxTotalBytes = 64 * 1_000_000
    let directory: URL
    private let queue = DispatchQueue(label: "now.calendar-cache", qos: .utility)

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.thomasboch.now", isDirectory: true)
            .appendingPathComponent("CalendarCache-v1", isDirectory: true)
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    func load(subscriptions: [CalendarSubscription]) async -> CalendarCacheLoad {
        await withCheckedContinuation { continuation in
            queue.async {
                var result = CalendarCacheLoad()
                var total = 0
                for subscription in subscriptions.filter(\.isEnabled).sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                    let url = self.file(subscription.id)
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    do {
                        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                        guard values.isRegularFile == true, values.isSymbolicLink != true,
                              let size = values.fileSize, size <= Self.maxSnapshotBytes,
                              size <= Self.maxTotalBytes - total else { throw CacheError.invalid }
                        total += size
                        // Bounded read also protects against a file growing after stat.
                        let handle = try FileHandle(forReadingFrom: url)
                        defer { try? handle.close() }
                        let data = try handle.read(upToCount: Self.maxSnapshotBytes + 1) ?? Data()
                        guard data.count <= Self.maxSnapshotBytes else { throw CacheError.invalid }
                        let snapshot = try JSONDecoder().decode(CalendarCacheSnapshot.self, from: data)
                        guard snapshot.isValid, snapshot.matches(subscription) else { throw CacheError.invalid }
                        result.snapshots[subscription.id] = snapshot
                    } catch {
                        result.issues[subscription.id] = "Saved calendar data could not be loaded. Refresh to restore offline availability."
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    func save(_ snapshot: CalendarCacheSnapshot, completion: @escaping @Sendable (String?) -> Void) {
        queue.async {
            do {
                guard snapshot.isValid,
                      snapshot.meetings.reduce(1024 + (snapshot.warning?.utf8.count ?? 0) * 6, { $0 + $1.estimatedBytes }) <= Self.maxSnapshotBytes
                else { throw CacheError.invalid }
                let data = try JSONEncoder().encode(snapshot)
                guard data.count <= Self.maxSnapshotBytes else { throw CacheError.invalid }
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.directory.path)
                let otherSize = try self.cacheFiles().filter { $0 != self.file(snapshot.calendarID) }.reduce(0) {
                    $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                guard data.count <= Self.maxTotalBytes - otherSize else { throw CacheError.invalid }
                try data.write(to: self.file(snapshot.calendarID), options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.file(snapshot.calendarID).path)
                completion(nil)
            } catch {
                // A successful new feed must not leave an older disk snapshot behind.
                try? FileManager.default.removeItem(at: self.file(snapshot.calendarID))
                completion("Calendar synced, but its offline copy could not be saved. It may be unavailable after restarting.")
            }
        }
    }

    func remove(_ ids: Set<UUID>) {
        queue.async { for id in ids { try? FileManager.default.removeItem(at: self.file(id)) } }
    }

    func retain(_ ids: Set<UUID>) {
        queue.async {
            for url in (try? self.cacheFiles()) ?? [] {
                if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), !ids.contains(id) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    /// Enqueue synchronously: AppKit's termination loop need not service Tasks.
    func whenIdle(_ completion: @escaping @Sendable () -> Void) {
        queue.async(execute: completion)
    }

    /// Await queued disk writes/removals, useful for controlled shutdown tests.
    func flush() async {
        await withCheckedContinuation { continuation in whenIdle { continuation.resume() } }
    }

    private func cacheFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]).filter {
            $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent)?.uuidString == $0.deletingPathExtension().lastPathComponent
        }
    }

    private enum CacheError: Error { case invalid }
}

struct CalendarCacheInfo {
    let fetchedAt: Date
    let coverageStart: Date
    let coverageEnd: Date
    var usingSavedData: Bool

    init(snapshot: CalendarCacheSnapshot, usingSavedData: Bool) {
        fetchedAt = snapshot.fetchedAt; coverageStart = snapshot.coverageStart
        coverageEnd = snapshot.coverageEnd; self.usingSavedData = usingSavedData
    }

    func covers(_ date: Date) -> Bool { date >= coverageStart && date <= coverageEnd }
}

struct CalendarTransportResult {
    var data: Data? = nil
    var error: String? = nil
    var isOffline = false

    static func isOffline(_ error: Error?) -> Bool {
        guard let error = error as NSError?, error.domain == NSURLErrorDomain else { return false }
        // DNS, timeouts, HTTP failures and refused connections do not prove offline.
        return error.code == NSURLErrorNotConnectedToInternet
    }
}
