import Foundation
import AppKit
import UserNotifications

@MainActor
final class FakeNotifications: NotificationTransport {
    var status = NotificationPermission(authorization: .allowed, alerts: true, sound: true)
    var submissions: [ReminderNotification] = []
    var removed: [String] = []
    var permissionRequests = 0
    var fail = false
    var hold = false
    var waiting: [CheckedContinuation<Void, Error>] = []
    func permission() async -> NotificationPermission { status }
    func requestPermission() async throws { permissionRequests += 1; status.authorization = .allowed }
    func add(_ notification: ReminderNotification) async throws {
        submissions.append(notification)
        if fail { throw NSError(domain: "fake", code: 1) }
        if hold { try await withCheckedThrowingContinuation { waiting.append($0) } }
    }
    func remove(_ ids: [String]) { removed += ids }
    func release() { let old = waiting; waiting = []; old.forEach { $0.resume() } }
}

@main
struct NotificationSmoke {
    @MainActor static func settle() async {
        for _ in 0..<30 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    @MainActor static func main() async {
        func require(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { print("FAIL: \(label)"); exit(1) }
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        if CommandLine.arguments.contains("--gui") { NotificationPreview.run(root: root); return }
        var clock = Date()
        let transport = FakeNotifications()
        let controller = ReminderNotificationController(transport: transport)
        controller.now = { clock }
        var submitted = 0
        controller.onSubmitted = { _ in submitted += 1 }
        let fixture = ReminderNotification(id: "now.fixture", keys: ["one"], fingerprints: ["one"], expires: clock.addingTimeInterval(300), catchUp: false,
                                          title: "SECRET", body: "SECRET", category: "test", sound: false)
        controller.offer(fixture, now: clock); controller.offer(fixture, now: clock)
        await settle()
        require(transport.submissions.count == 1 && submitted == 1, "async submission reserves occurrence exactly once")
        let saved = UserDefaults.standard.data(forKey: "local.tboch.now.notification-receipts.v1")!
        require(!String(data: saved, encoding: .utf8)!.contains("SECRET"), "receipt storage omits notification text")
        let restored = ReminderNotificationController(transport: transport)
        require(restored.receipts.count == 1, "receipt restored across controller restart")
        controller.discard(controller.receipts.keys.first!)
        transport.status.authorization = .denied
        controller.offer(fixture, now: clock); await settle()
        require(transport.submissions.count == 1 && controller.receipts.isEmpty, "denied permission neither submits nor marks handled")
        controller.offer(fixture, now: clock); await settle()
        require(transport.submissions.count == 1, "denied request backs off")
        transport.status.authorization = .allowed
        controller.refreshPermission(force: true, now: clock); await settle()
        transport.fail = true
        controller.offer(fixture, now: clock); await settle()
        require(controller.problem != nil && submitted == 1, "failed add remains retryable, never acknowledged")
        clock = clock.addingTimeInterval(61)
        transport.fail = false; transport.hold = true
        controller.offer(fixture, now: clock); await settle()
        let oldID = controller.receipts.keys.first!
        controller.discard(oldID)
        controller.offer(fixture, now: clock); await settle()
        let replacementID = controller.receipts.keys.first!
        require(oldID != replacementID, "replacement owns new request token")
        transport.release(); await settle()
        require(controller.receipts[replacementID] != nil && !transport.removed.contains(replacementID), "late old completion cannot delete replacement")
        require(submitted == 2, "stale completion cannot acknowledge")
        controller.discard(replacementID)
        transport.hold = false
        let beforeTests = transport.submissions.count
        controller.test(sound: false); await settle()
        let firstTest = transport.submissions.last!
        controller.test(sound: false); await settle()
        let repeatedTest = transport.submissions.last!
        require(transport.submissions.count == beforeTests + 2 && firstTest.id != repeatedTest.id,
                "identical test text can be sent repeatedly with fresh request IDs")
        require(transport.removed.contains(firstTest.id) && controller.receipts.count == 1,
                "repeated tests replace old sample receipts without accumulating notifications")
        var previewSettings = AppSettings()
        controller.previewMeeting(settings: previewSettings); await settle()
        require(transport.submissions.last?.title == AlertController.previewEvent(at: clock).title,
                "notification preview shares fullscreen dummy meeting")
        previewSettings.hideNotificationDetails = true
        controller.previewMeeting(settings: previewSettings); await settle()
        require(transport.submissions.last?.title == "A meeting is starting", "notification preview honors privacy")
        require(transport.submissions.last?.keys.isEmpty == true && transport.submissions.last?.test == true,
                "notification preview has no real event identity or real actions")
        for id in Array(controller.receipts.keys) { controller.discard(id) }

        // Production AppStore orchestration, isolated preferences/cache and no UI.
        let base = Date()
        clock = base
        let source = CalendarSubscription(name: "Synthetic", url: "http://127.0.0.1:1/test", colorIndex: 0)
        var settings = AppSettings(); settings.reminderDelivery = .notification; settings.soundEnabled = false
        let state = Persisted(subscriptions: [source], settings: settings)
        let store = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("cache")), initialState: state)
        store.now = { clock }
        let system = FakeNotifications()
        let delivery = ReminderNotificationController(transport: system)
        delivery.now = { clock }
        store.connectNotifications(delivery)
        var fullscreen: [String] = []
        store.onAlert = { fullscreen += $0.map(\.id) }
        await store.restoreCachedEvents()
        func meeting(_ id: String, start: TimeInterval = 120, end: TimeInterval = 1800, muted: Bool = false) -> MeetingEvent {
            MeetingEvent(uid: id, title: "Synthetic \(id)", start: base.addingTimeInterval(start), end: base.addingTimeInterval(end), location: nil, notes: nil,
                         link: nil, calendarID: source.id, calendarName: source.name, colorIndex: 0, isMuted: muted)
        }
        let one = meeting("one")
        store.commitEvents([one]); store.tick(); store.tick(); await settle()
        require(system.submissions.count == 1 && fullscreen.isEmpty, "notification mode never presents fullscreen")
        store.tick(); await settle()
        require(system.submissions.count == 1, "accepted notification does not repeat each tick")
        let token = delivery.receipts.keys.first!
        delivery.receive(id: token, action: "snooze")
        clock = one.start.addingTimeInterval(-1); store.tick(); await settle()
        require(system.submissions.count == 1, "at-start snooze remains quiet before start")
        clock = one.start; store.tick(); await settle()
        require(system.submissions.count == 2, "notification snooze re-fires at exact deadline")
        delivery.receive(id: delivery.receipts.keys.first!, action: UNNotificationDismissActionIdentifier)
        store.tick(); await settle()
        require(system.submissions.count == 2, "explicit dismiss stays handled")

        // Real preferences reload: saved settings contain only synthetic source.
        let restarted = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("cache2")))
        restarted.now = { clock }
        await restarted.restoreCachedEvents()
        restarted.commitEvents([one])
        var restartedAlerts = 0
        restarted.onAlert = { restartedAlerts += $0.count }
        let restartTransport = FakeNotifications()
        let restartDelivery = ReminderNotificationController(transport: restartTransport)
        restarted.connectNotifications(restartDelivery)
        restarted.tick(); await settle()
        require(restartTransport.submissions.isEmpty && restartedAlerts == 0, "dismiss survives AppStore restart")

        let two = meeting("two", start: 240)
        store.commitEvents([one, two])
        system.status.authorization = .denied
        store.tick(); await settle()
        require(system.submissions.count == 2 && fullscreen.isEmpty, "permission revocation has no fullscreen fallback")
        system.status.authorization = .allowed
        delivery.refreshPermission(force: true, now: clock); await settle()
        store.tick(); await settle()
        require(system.submissions.count == 3, "permission recovery retries still-due reminder")
        store.settings.hideNotificationDetails = true
        require(delivery.receipts.isEmpty, "privacy edit immediately removes previously delivered details")

        let three = meeting("three", start: 280)
        system.hold = true
        store.commitEvents([one, two, three]); store.tick(); await settle()
        let staleID = delivery.receipts.keys.first!
        store.commitEvents([one, two]); system.release(); await settle()
        require(delivery.receipts.isEmpty && system.removed.contains(staleID), "event removed during add removes stale notification")
        system.hold = false
        store.commitEvents([one, two, three]); store.tick(); await settle()
        require(delivery.receipts.count == 1, "stale add never marks returned event handled")
        store.pauseIndefinitely(); store.tick(); await settle()
        require(delivery.receipts.isEmpty, "pause removes delivered notifications")
        store.resume()

        clock = base.addingTimeInterval(600)
        store.settings.reminderDelivery = .fullscreen
        store.settings.notifyOnCatchUp = true
        let runningA = meeting("runningA", start: 300), runningB = meeting("runningB", start: 400)
        store.beginNotificationCatchUp()
        store.isRefreshing = true
        store.commitEvents([runningA]); store.tick(); await settle()
        let beforeSecondSource = system.submissions.count
        store.commitEvents([runningA, runningB]); store.tick(); await settle()
        require(system.submissions.count == beforeSecondSource, "catch-up waits for asynchronous refresh completion")
        store.finishRefresh(fetched: [source]); await settle()
        require(system.submissions.last?.keys.count == 2 && system.submissions.last?.catchUp == true, "wake groups running meetings")
        let before = system.submissions.count
        store.beginNotificationCatchUp(); store.tick(); await settle()
        require(system.submissions.count == before && fullscreen.isEmpty, "repeated wake does not duplicate catch-up")
        clock = base.addingTimeInterval(1900); store.tick(); await settle()
        require(delivery.receipts.isEmpty, "ended meetings removed from Notification Center")
        store.settings.notifySyncErrors = true
        store.merge(results: [FetchResult(subscription: source, events: [], error: "Synthetic failure")])
        store.finishRefresh(fetched: [source])
        store.pauseIndefinitely()
        let beforeError = system.submissions.count
        clock = clock.addingTimeInterval(299); store.tick(); await settle()
        require(system.submissions.count == beforeError, "sync problem does not notify before sustained-failure threshold")
        clock = clock.addingTimeInterval(1); store.tick(); await settle()
        require(system.submissions.count == beforeError + 1 && system.submissions.last?.sync == true, "sync error notifies independently of reminder pause")
        delivery.receive(id: delivery.receipts.keys.first!, action: UNNotificationDismissActionIdentifier)
        clock = clock.addingTimeInterval(600); store.tick(); await settle()
        require(system.submissions.count == beforeError + 1, "dismissed sync error does not repeat unchanged")
        let errorRestart = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("cache3")))
        errorRestart.now = { clock }
        let errorTransport = FakeNotifications()
        let errorDelivery = ReminderNotificationController(transport: errorTransport)
        errorDelivery.now = { clock }
        errorRestart.connectNotifications(errorDelivery)
        await errorRestart.restoreCachedEvents()
        errorRestart.merge(results: [FetchResult(subscription: source, events: [], error: "Still failing")])
        errorRestart.finishRefresh(fetched: [source]); await settle()
        require(errorTransport.submissions.isEmpty, "continuous failure stays quiet across restart")
        store.merge(results: [FetchResult(subscription: source, events: [], error: nil)])
        store.tick()
        store.merge(results: [FetchResult(subscription: source, events: [], error: "New failure")])
        store.tick()
        clock = clock.addingTimeInterval(300); store.tick(); await settle()
        require(system.submissions.count == beforeError + 2, "recovery re-arms a new failure episode")
        // Setup permission is explicit and denied permission never re-prompts.
        let beforeSetup = store.settings
        system.status.authorization = .denied
        let deniedSetup = await delivery.authorizeForSetup()
        require(!deniedSetup && system.permissionRequests == 0 && store.settings == beforeSetup, "setup denial preserves settings without re-prompting")
        system.status.authorization = .notRequested
        let allowedSetup = await delivery.authorizeForSetup()
        require(allowedSetup && system.permissionRequests == 1, "setup requests undecided permission exactly once")
        _ = await delivery.authorizeForSetup()
        require(system.permissionRequests == 1, "setup does not re-request an existing grant")
        let guides = FeatureGuideController()
        store.featureGuides = guides
        require(UserDefaults.standard.data(forKey: FeatureGuideController.storageKey) == nil, "guide does not consume introduction before health acknowledgement")
        var installedState = UpdateState()
        installedState.pendingInstallVersion = UpdateLogic.currentVersion
        UserDefaults.standard.set(try! JSONEncoder().encode(installedState), forKey: UpdateController.stateKey)
        let updater = UpdateController(store: store)
        require(guides.updateIDs.isEmpty, "update guide remains hidden before health commit")
        updater.startupHealthAcknowledged()
        require(guides.updateIDs == [FeatureGuideCatalog.notificationsID], "successful update presents new guide")
        if case .installed = updater.windowContent {} else { require(false, "success dialog follows health commit") }
        if let directory = ProcessInfo.processInfo.environment["NOW_NOTIFICATION_RENDER_DIR"] {
            // Render production views with untouched default choices, entirely
            // offline. Never construct SystemNotificationTransport here.
            let previewDomain = "now-initial-guide-" + UUID().uuidString
            let previewDefaults = UserDefaults(suiteName: previewDomain)!
            let previewStore = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("visual-cache")),
                                        initialState: Persisted(subscriptions: [source], settings: AppSettings()))
            let previewTransport = FakeNotifications()
            previewTransport.status.authorization = .notRequested
            let previewDelivery = ReminderNotificationController(transport: previewTransport, defaults: previewDefaults)
            previewStore.connectNotifications(previewDelivery)
            let updateGuides = FeatureGuideController(defaults: previewDefaults)
            updateGuides.startupHealthAcknowledged(installedUpdate: true, hasCalendar: true)
            previewStore.featureGuides = updateGuides
            let previewUpdates = UpdateController(store: previewStore)
            previewUpdates.windowContent = .installed(version: "1.11.0")
            NotificationPreview.render(UpdateView(controller: previewUpdates), size: NSSize(width: 460, height: 424), name: "update-guide", directory: directory)
            previewDefaults.removePersistentDomain(forName: previewDomain)
            let initialGuides = FeatureGuideController(defaults: previewDefaults)
            initialGuides.startupHealthAcknowledged(installedUpdate: false, hasCalendar: true)
            previewStore.featureGuides = initialGuides
            let previewAlerts = AlertController()
            NotificationPreview.renderSettings(store: previewStore, alerts: previewAlerts, updates: previewUpdates, directory: directory)
            previewDefaults.removePersistentDomain(forName: previewDomain)
        }
        updater.dismissWindow()
        let nextGuides = FeatureGuideController()
        nextGuides.startupHealthAcknowledged(installedUpdate: true, hasCalendar: true)
        require(nextGuides.updateIDs.isEmpty && nextGuides.settingsIDs.isEmpty, "closed guide does not reappear after next update")
        store.settings.notifySyncErrors = false
        store.settings.notifyUpdates = true
        store.settings.automaticUpdateChecks = true
        system.status.authorization = .allowed
        let release = UpdateManifest(version: "999.0.0", zipURL: URL(string: "https://example.com/update.zip")!, assetSize: 1, publishedAt: Date().addingTimeInterval(-4 * 86400), notes: "Synthetic")
        let priorUpdates = system.submissions.count
        updater.state.firstSeenUpdateVersion = release.version
        updater.state.firstSeenUpdateDate = Date().addingTimeInterval(-4 * 86400)
        updater.stagedVersion = release.version
        updater.applyDecision(.available(release), userInitiated: false)
        store.tick(); await settle()
        require(system.submissions.count == priorUpdates + 1 && system.submissions.last?.updateVersion == release.version && system.submissions.last?.sound == false, "update notification submits silently while reminders paused")
        require(updater.windowContent == nil, "automatic update notification does not open update window")
        let updateToken = delivery.receipts.values.first { $0.updateVersion == release.version }!.id
        store.tick(); await settle()
        require(system.submissions.count == priorUpdates + 1, "update does not notify repeatedly")
        delivery.receive(id: updateToken, action: UNNotificationDefaultActionIdentifier)
        if case .available(let shown) = updater.windowContent { require(shown.version == release.version, "update click opens matching release") }
        else { require(false, "update click opens existing update window") }
        updater.dismissWindow()
        let updateRestart = UpdateController(store: store)
        updateRestart.applyDecision(.available(release), userInitiated: false)
        store.tick(); await settle()
        require(system.submissions.count == priorUpdates + 1, "update notification marker survives restart and dismissal")
        var nextRelease = release
        nextRelease.version = "999.1.0"
        updateRestart.applyDecision(.available(nextRelease), userInitiated: false)
        await settle()
        require(system.submissions.count == priorUpdates + 2, "new version can notify once")
        updateRestart.applyDecision(.upToDate, userInitiated: false)
        require(!delivery.receipts.values.contains { $0.updateVersion != nil }, "withdrawn updates removed from Notification Center")
        nextRelease.version = "999.2.0"
        system.hold = true
        updateRestart.applyDecision(.available(nextRelease), userInitiated: false)
        await settle()
        store.settings.notifyUpdates = false
        system.release(); await settle()
        require(updateRestart.state.lastNotificationVersion == "999.1.0", "disabled in-flight update does not consume version")
        require(!delivery.receipts.values.contains { $0.updateVersion != nil }, "disabling update notices removes pending receipt")
        system.hold = false
        updateRestart.applyDecision(.available(nextRelease), userInitiated: true)
        if case .available = updateRestart.windowContent {} else { require(false, "manual check opens window even with update notices disabled") }
        print("NOTIFICATION SMOKE OK — async races, permission recovery, routing, privacy, snooze, restart, wake grouping, cleanup, update notices, feature migration")
    }
}
