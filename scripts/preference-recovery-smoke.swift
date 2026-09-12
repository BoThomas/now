import Foundation
import NowCore
import AppKit

extension NotificationSmoke {
    @MainActor static func preferenceRecoveryTests(root: URL) async {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { print("FAIL: \(message)"); exit(1) }
            print("PASS: \(message)")
        }
        let domain = Bundle.main.bundleIdentifier!
        precondition(domain.hasPrefix("com.thomasboch.now.notification-smoke."))
        let defaults = UserDefaults.standard
        let legacy = UserDefaults(suiteName: AppStore.legacyDomain)!
        defer {
            defaults.removePersistentDomain(forName: domain)
            legacy.removePersistentDomain(forName: AppStore.legacyDomain)
        }
        let key = AppStore.storageKey
        let cache = CalendarEventCache(directory: root.appendingPathComponent("recovery-cache"))
        var sub = CalendarSubscription(name: "Kept calendar", url: "https://example.invalid/private-token", colorIndex: 0)
        sub.id = UUID()
        var state = Persisted(subscriptions: [sub]); state.settings.leadSeconds = 37
        require(StoredPreferences.load(Persisted.self, key: key, label: "Test profile") == nil, "absent preferences stay absent")
        require(!StoredPreferences.needsReview(key), "first launch does not claim damage")
        StoredPreferences.save(state, key: key, label: "Test profile")
        let damaged = Data("{truncated".utf8)
        defaults.set(damaged, forKey: key)
        let orphan = root.appendingPathComponent("recovery-cache/\(UUID().uuidString).json")
        try! FileManager.default.createDirectory(at: cache.directory, withIntermediateDirectories: true)
        try! Data("offline snapshot".utf8).write(to: orphan)
        var newerURL = sub; newerURL.url = "https://example.invalid/newer-token"
        let cached = CalendarCacheSnapshot(subscription: newerURL, events: [], fetchedAt: Date(), warning: nil)
        await withCheckedContinuation { continuation in cache.save(cached) { _ in continuation.resume() } }
        let mismatchedPath = cache.directory.appendingPathComponent(sub.id.uuidString + ".json")
        let recovered = AppStore(eventCache: cache)
        await cache.flush()
        require(recovered.subscriptions.map(\.id) == [sub.id] && recovered.settings.leadSeconds == 37, "startup restores verified profile backup")
        require((defaults.array(forKey: StoredPreferences.recoveryKey(key))?.first as? Data) == damaged, "startup migration preserves original damaged bytes")
        require(FileManager.default.fileExists(atPath: orphan.path), "recovered startup preserves orphaned cache files")
        require(FileManager.default.fileExists(atPath: mismatchedPath.path), "older recovered URL cannot delete a newer source snapshot")
        let restarted = AppStore(eventCache: cache)
        await cache.flush()
        require(restarted.subscriptions.count == 1 && FileManager.default.fileExists(atPath: orphan.path), "recovery protection survives the next launch")
        PersistenceStatus.shared.reviewed(key)
        require(!StoredPreferences.needsReview(key) && defaults.array(forKey: StoredPreferences.recoveryKey(key)) != nil, "review acknowledgement keeps recovery bytes")

        let rotationKey = "test.recovery-rotation"
        let failures = (0..<6).map { Data("{damaged-\($0)".utf8) }
        let expectedCopies = [[0], [0, 1], [0, 1, 2], [0, 2, 3], [0, 3, 4], [0, 4, 5]]
        for (index, payload) in failures.enumerated() {
            defaults.set(payload, forKey: rotationKey)
            _ = StoredPreferences.load(Persisted.self, key: rotationKey, label: "Test rotation")
            let expected = expectedCopies[index].map { failures[$0] }
            require(defaults.array(forKey: StoredPreferences.recoveryKey(rotationKey)) as? [Data] == expected,
                    "recovery \(index + 1) retains the original and at most two latest distinct failures")
            _ = StoredPreferences.load(Persisted.self, key: rotationKey, label: "Test rotation")
            require(defaults.array(forKey: StoredPreferences.recoveryKey(rotationKey)) as? [Data] == expected,
                    "rereading recovery \(index + 1) does not duplicate or rotate copies")
        }
        PersistenceStatus.shared.reviewed(rotationKey)
        defaults.set(failures[0], forKey: rotationKey)
        _ = StoredPreferences.load(Persisted.self, key: rotationKey, label: "Test rotation")
        require(defaults.array(forKey: StoredPreferences.recoveryKey(rotationKey)) as? [Data] == [failures[0], failures[4], failures[5]],
                "repeated original damage preserves the newest recovery copies")
        require(StoredPreferences.needsReview(rotationKey), "damage after acknowledgement reopens the recovery notice")

        defaults.removePersistentDomain(forName: domain)
        let lossy = Data("{\"subscriptions\":[{\"name\":\"Good\",\"url\":\"https://example.invalid\"},{\"name\":false}],\"settings\":{\"leadSeconds\":\"bad\",\"soundEnabled\":false}}".utf8)
        defaults.set(lossy, forKey: key)
        let partial = AppStore(eventCache: cache)
        await cache.flush()
        require(partial.subscriptions.map(\.name) == ["Good"] && !partial.settings.soundEnabled, "partial recovery keeps valid siblings and settings")
        require(partial.subscriptions.first?.colorHex == Palette.hex(for: 0), "profile recovery resolves legacy colors with the macOS palette")
        require(StoredPreferences.needsReview(key), "lossy successful decoding raises recovery notice")
        require((defaults.array(forKey: StoredPreferences.recoveryKey(key))?.first as? Data) == lossy, "lossy migration preserves original data")

        defaults.removePersistentDomain(forName: domain)
        defaults.set(Data("{\"subscriptions\":null,\"settings\":{},\"pausedUntil\":null}".utf8), forKey: key)
        _ = StoredPreferences.load(Persisted.self, key: key, label: "Test null fields")
        require(StoredPreferences.needsReview(key), "null required collection is preserved as a lossy decode")
        defaults.removePersistentDomain(forName: domain)
        defaults.set(Data("{\"settings\":{\"skippedUpdateVersion\":null},\"pausedUntil\":null}".utf8), forKey: key)
        _ = StoredPreferences.load(Persisted.self, key: key, label: "Test optional fields")
        require(!StoredPreferences.needsReview(key), "missing migration fields and optional nulls remain valid")

        defaults.removePersistentDomain(forName: domain)
        legacy.set(try! JSONEncoder().encode(state), forKey: key)
        defaults.set("wrong preference type", forKey: key)
        require(AppStore.loadState().subscriptions.isEmpty, "damaged current profile does not resurrect legacy state")
        require(defaults.array(forKey: StoredPreferences.recoveryKey(key))?.first as? String == "wrong preference type", "non-Data preference payload is preserved")
        defaults.removePersistentDomain(forName: domain)
        require(AppStore.loadState().subscriptions.count == 1, "absent current profile still migrates legacy data")

        let ledgerKey = "local.tboch.now.reminder-ledger.v1"
        let date = Date()
        let event = MeetingEvent(uid: "handled", title: "Handled", start: date, end: date.addingTimeInterval(300), location: nil, notes: nil, link: nil, calendarID: sub.id, calendarName: sub.name, colorIndex: 0)
        var ledger = ReminderLedger(); ledger.record(event, snooze: date.addingTimeInterval(30))
        StoredPreferences.save(ledger, key: ledgerKey, label: "Test history")
        defaults.set(damaged, forKey: ledgerKey)
        let history = StoredPreferences.load(ReminderLedger.self, key: ledgerKey, label: "Test history")
        require(history?.entries[NotificationLogic.eventKey(event)]?.snooze == date.addingTimeInterval(30), "damaged ledger restores handled/snoozed history")
        let oldPayload = defaults.data(forKey: key)
        struct BadEncoding: Encodable { let value = Double.nan }
        require(!StoredPreferences.save(BadEncoding(), key: key, label: "Test encoding"), "encoding failure is reported")
        require(defaults.data(forKey: key) == oldPayload, "encoding failure preserves saved profile")
        require(PersistenceStatus.shared.issues[key] != nil, "persistence failures are visible")

        require(MeetingActivityProbe.objectCount(byteCount: 1) == nil && MeetingActivityProbe.objectCount(byteCount: 5) == nil, "CoreAudio rejects undersized and nonintegral buffers")
        require(MeetingActivityProbe.objectCount(byteCount: 8) == 2 && MeetingActivityProbe.objectCount(byteCount: 0, allowEmpty: true) == 0, "CoreAudio accepts complete and empty returned lists")
        let task = Task { await UpdateStaging.extract("/bin/sleep", ["10"], monitoredDirectory: root, limits: .production) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let began = Date(); task.cancel()
        let result = await task.value
        require(result == .cancelled && Date().timeIntervalSince(began) < 3, "queued extraction cancellation stops its process promptly")
        let artifacts = root.appendingPathComponent("artifact-cleanup")
        let trash = artifacts.appendingPathComponent("Trash")
        let app = artifacts.appendingPathComponent("now.app")
        try! FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let old = artifacts.appendingPathComponent("now.app.old-" + UUID().uuidString + ".failed")
        let recent = artifacts.appendingPathComponent("now.app.old-" + UUID().uuidString + ".failed")
        let activeBackup = artifacts.appendingPathComponent("now.app.old-" + UUID().uuidString)
        let active = URL(fileURLWithPath: activeBackup.path + ".failed")
        for item in [old, recent, active] {
            try! FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
            try! FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(item == recent ? -60 : -90_000)], ofItemAtPath: item.path)
        }
        setenv("NOW_UPDATE_ACTIVE_BACKUP", activeBackup.path, 1)
        defer { unsetenv("NOW_UPDATE_ACTIVE_BACKUP") }
        UpdateStaging.cleanupLaunchArtifacts(bundlePath: app.path, now: date, trashDirectory: trash, signatureCheck: { _ in false })
        require(FileManager.default.fileExists(atPath: old.path), "failed artifact retained if installed app cannot be verified")
        UpdateStaging.cleanupLaunchArtifacts(bundlePath: app.path, now: date, trashDirectory: trash, signatureCheck: { $0.path == app.path })
        require(!FileManager.default.fileExists(atPath: old.path) && (try! FileManager.default.contentsOfDirectory(atPath: trash.path)).count == 1, "old failed artifact moves to isolated Trash after installed app verification")
        require(FileManager.default.fileExists(atPath: recent.path) && FileManager.default.fileExists(atPath: active.path), "recent and helper-owned failed artifacts stay protected")
        print("PREFERENCE RECOVERY SMOKE OK")
    }
}
