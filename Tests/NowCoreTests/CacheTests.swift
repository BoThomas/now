import Foundation
import NowCore

extension CoreTests {
    static var cacheSubscription: CalendarSubscription {
        var sub = CalendarSubscription(name: "Calendar", url: "https://example.invalid/feed?token=TEST%2BONLY#one", colorIndex: 0, colorHex: "#123456")
        sub.id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        return sub
    }

    static func cachePolicy(_ check: inout Check) throws {
        for (input, digest) in [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("réunion📅\0", "ba82859c24c2969479651dc30d4e34c3b35c1393d4d78b778ebb6c83c62be1fa")
        ] { check.expect(StableDigest.sha256(input) == digest, "independent SHA-256 vector, including exact Unicode/NUL bytes") }
        let sub = cacheSubscription
        let item = modelEvent(calendarID: sub.id, identity: "ics:3:uid:1800000000.0")
        let snapshot = CalendarCacheSnapshot(subscription: sub, events: [item], fetchedAt: item.start, warning: "synthetic warning")
        check.expect(snapshot.sourceFingerprint == "2a5a1784541426a6abef5712b8d07bc92c1e634922b8dcadde67bca4937ddcc3", "saved URL fingerprint matches independent pre-extraction vector")
        check.expect(snapshot.isValid && snapshot.coverageStart == item.start.addingTimeInterval(-21600)
                     && snapshot.coverageEnd == item.start.addingTimeInterval(1209600), "exact original cache coverage")
        var live = sub; live.colorHex = "#abcdef"; live.name = "Renamed"
        let restored = snapshot.events(subscription: live, now: item.start)
        check.expect(restored.first?.id == item.id && restored.first?.notificationIdentity == item.notificationIdentity, "cache restores occurrence identities")
        check.expect(restored.first?.colorHex == live.colorHex && restored.first?.calendarName == live.name, "cache applies live presentation")
        check.expect(snapshot.events(subscription: sub, now: item.end).isEmpty, "cache excludes exclusive ended boundary")
        check.expect(snapshot.events(subscription: sub, now: snapshot.coverageStart.addingTimeInterval(-0.001)).isEmpty, "cache never extends saved coverage")
        live.url += "changed"
        check.expect(!snapshot.matches(live), "URL change invalidates snapshot binding")
        live = sub; live.isEnabled = false
        check.expect(!snapshot.matches(live), "disabled source cannot restore")
        var badVersion = snapshot; badVersion.version = 99
        check.expect(!badVersion.isValid, "unknown cache schema rejected")
        let data = try JSONEncoder().encode(snapshot)
        let reread = try JSONDecoder().decode(CalendarCacheSnapshot.self, from: data)
        check.expect(reread.events(subscription: sub, now: item.start).map(\.id) == [item.id], "snapshot wire round trip")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        check.expect(Set(json.keys) == ["version", "calendarID", "sourceFingerprint", "fetchedAt", "coverageStart", "coverageEnd", "warning", "meetings"], "cache wire keys unchanged")
        check.expect(!String(decoding: data, as: UTF8.self).contains("TEST%2BONLY"), "feed token is not stored in cache metadata")
        var damaged = json; damaged["coverageEnd"] = -1
        let invalid = try JSONDecoder().decode(CalendarCacheSnapshot.self, from: JSONSerialization.data(withJSONObject: damaged))
        check.expect(!invalid.isValid, "decoded invalid coverage is rejected")
    }

    #if os(macOS) || os(Linux)
    static func save(_ snapshot: CalendarCacheSnapshot, to cache: CalendarEventCache) async -> String? {
        await withCheckedContinuation { continuation in cache.save(snapshot) { continuation.resume(returning: $0) } }
    }

    static func cacheStorage(_ check: inout Check) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("now-core-cache-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = cacheSubscription
        let item = modelEvent(calendarID: sub.id)
        let cache = CalendarEventCache(directory: root)
        let snapshot = CalendarCacheSnapshot(subscription: sub, events: [item], fetchedAt: item.start, warning: nil)
        check.expect(await save(snapshot, to: cache) == nil, "POSIX snapshot save")
        let file = root.appendingPathComponent(sub.id.uuidString + ".json")
        let recovery = root.appendingPathComponent(sub.id.uuidString + ".recovery.json")
        let dirMode = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as! NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        check.expect(dirMode.intValue == 0o700 && fileMode.intValue == 0o600, "private directory/file permissions")
        let reopened = await CalendarEventCache(directory: root).load(subscriptions: [sub])
        check.expect(reopened.snapshots[sub.id]?.meetings.count == 1, "fresh cache instance reads saved snapshot")

        // A sparse competing snapshot exceeds the disk budget without a large allocation.
        let blocker = root.appendingPathComponent(UUID().uuidString + ".json")
        _ = FileManager.default.createFile(atPath: blocker.path, contents: nil)
        let handle = try FileHandle(forWritingTo: blocker)
        try handle.truncate(atOffset: UInt64(CalendarEventCache.maxTotalBytes + 1)); try handle.close()
        let empty = CalendarCacheSnapshot(subscription: sub, events: [], fetchedAt: item.start, warning: nil)
        check.expect(await save(empty, to: cache) != nil, "failed accepted-empty save reports storage issue")
        check.expect(!FileManager.default.fileExists(atPath: file.path) && FileManager.default.fileExists(atPath: recovery.path), "obsolete live snapshot quarantined on failure")
        let failedRestart = await CalendarEventCache(directory: root).load(subscriptions: [sub])
        check.expect(failedRestart.snapshots.isEmpty, "failed-empty save cannot resurrect meetings after restart")
        cache.retain([sub.id]); await cache.flush()
        check.expect(await save(empty, to: cache) == nil && !FileManager.default.fileExists(atPath: recovery.path), "successful replacement retires recovery copy")

        try Data("{broken".utf8).write(to: file)
        let protected = await cache.load(subscriptions: [sub], retireInvalidSnapshots: false)
        check.expect(protected.issues[sub.id] != nil && FileManager.default.fileExists(atPath: file.path), "profile recovery preserves invalid snapshot bytes")
        _ = await cache.load(subscriptions: [sub])
        check.expect(!FileManager.default.fileExists(atPath: file.path), "ordinary validated corruption is retired")
        let target = root.appendingPathComponent("symlink-target")
        try JSONEncoder().encode(snapshot).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        _ = await cache.load(subscriptions: [sub])
        check.expect(FileManager.default.fileExists(atPath: target.path) && !FileManager.default.fileExists(atPath: file.path), "symlink rejection preserves target bytes")

        cache.save(snapshot) { _ in }
        cache.remove([sub.id]); await cache.flush()
        check.expect(!FileManager.default.fileExists(atPath: file.path), "serial removal follows queued save")
        for mode in ["--cache-write", "--cache-read"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = [mode, root.path]
            try process.run(); process.waitUntilExit()
            check.expect(process.terminationStatus == 0, "real process cache/ledger restart: \(mode)")
        }
    }

    static func cacheChild(mode: String, directory: URL) async throws {
        let sub = cacheSubscription
        let item = modelEvent(calendarID: sub.id, identity: "ics:3:uid:1800000000.0")
        let cache = CalendarEventCache(directory: directory)
        let ledgerURL = directory.appendingPathComponent("ledger.json")
        if mode == "--cache-write" {
            let snapshot = CalendarCacheSnapshot(subscription: sub, events: [item], fetchedAt: item.start, warning: nil)
            guard await save(snapshot, to: cache) == nil else { throw CocoaError(.fileWriteUnknown) }
            var ledger = ReminderLedger(); ledger.record(item)
            try JSONEncoder().encode(ledger).write(to: ledgerURL)
        } else if mode == "--cache-read" {
            let loaded = await cache.load(subscriptions: [sub])
            let events = loaded.snapshots[sub.id]?.events(subscription: sub, now: item.start) ?? []
            let ledger = try JSONDecoder().decode(ReminderLedger.self, from: Data(contentsOf: ledgerURL))
            let handled = Set(events.filter { ledger.entries[ReminderIdentity.eventKey($0)] != nil }.map(\.id))
            guard events.map(\.id) == [item.id], handled == [item.id],
                  ReminderTiming.dueForAlert(events: events, alerted: handled, snoozed: [:], leadSeconds: 300, now: item.start).isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } else { throw CocoaError(.featureUnsupported) }
    }
    #endif
}
