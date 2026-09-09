import Foundation
import AppKit
import UserNotifications

@MainActor
final class FakeNotifications: NotificationTransport {
    var status = NotificationPermission(authorization: .allowed, alerts: true, sound: true)
    var submissions: [ReminderNotification] = []
    var removed: [String] = []
    var response: ((String, String) -> Void)?
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

@MainActor
final class ScriptedMeetingProbe {
    var result: Result<[MeetingAudioOwner], MeetingActivityProbeError> = .failure(.inputStateUnavailable)
    var calls = 0
    var hold = false
    var waiting: CheckedContinuation<Result<[MeetingAudioOwner], MeetingActivityProbeError>, Never>?
    func snapshot() async -> Result<[MeetingAudioOwner], MeetingActivityProbeError> {
        calls += 1
        if hold { return await withCheckedContinuation { waiting = $0 } }
        return result
    }
}

@main
struct NotificationSmoke {
    @MainActor static func settle() async {
        for _ in 0..<30 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    @MainActor static func pumpPreviewTimer() {
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
    }
    @MainActor static func main() async {
        func require(_ condition: @autoclosure () -> Bool, _ label: String) {
            if !condition() { print("FAIL: \(label)"); exit(1) }
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        if CommandLine.arguments.contains("--startup-new") { SetupAppSmoke.run(existingProfile: false); return }
        if CommandLine.arguments.contains("--startup-legacy") { SetupAppSmoke.run(existingProfile: true, legacyProfile: true); return }
        if CommandLine.arguments.contains("--startup-existing") { SetupAppSmoke.run(existingProfile: true); return }
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
                "notification preview has no real event identity")
        require(transport.submissions.last?.category == SystemNotificationTransport.category(join: false, snooze: true),
                "sample notification offers safe snooze without a real Join action")
        previewSettings.leadSeconds = 60
        previewSettings.snoozeSeconds = 1
        controller.previewMeeting(settings: previewSettings); await settle()
        let sampleCount = transport.submissions.count
        let sampleToken = controller.receipts.values.first { $0.test }!.id
        controller.receive(id: sampleToken, action: "snooze")
        clock = clock.addingTimeInterval(1)
        pumpPreviewTimer()
        await settle()
        require(transport.submissions.count == sampleCount && !controller.receipts.values.contains { $0.test },
                "preview snooze dismisses the sample without scheduling another reminder")
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
        func meeting(_ id: String, start: TimeInterval = 120, end: TimeInterval = 1800, muted: Bool = false, link: URL? = nil) -> MeetingEvent {
            MeetingEvent(uid: id, title: "Synthetic \(id)", start: base.addingTimeInterval(start), end: base.addingTimeInterval(end), location: nil, notes: nil,
                         link: link, calendarID: source.id, calendarName: source.name, colorIndex: 0, isMuted: muted)
        }
        do {
            let groupedStore = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("grouped-cache")), initialState: state)
            groupedStore.now = { clock }
            let groupedTransport = FakeNotifications()
            let groupedDelivery = ReminderNotificationController(transport: groupedTransport)
            groupedDelivery.now = { clock }
            groupedStore.connectNotifications(groupedDelivery)
            await groupedStore.restoreCachedEvents()
            let a = meeting("group-a", start: 30, link: URL(string: "https://example.com/a")!)
            let b = meeting("group-b", start: 30)
            let other = meeting("group-other", start: 31, link: URL(string: "https://example.com/other")!)
            groupedStore.commitEvents([other, b, a]); groupedStore.tick(); await settle()
            require(groupedTransport.submissions.count == 2, "same start gets one banner while a one-second difference stays separate")
            let banner = groupedDelivery.receipts.values.first { $0.keys.count == 2 }!
            require(banner.category == SystemNotificationTransport.chooseMeetingCategory && !banner.catchUp, "ordinary group offers Choose Meeting")
            require(banner.body.contains(a.title) && banner.body.contains(b.title) && !banner.title.contains("in progress"), "upcoming group lists titles without claiming meetings started")
            let privateText = NotificationLogic.content(events: [a, b], privateDetails: true, catchUp: false, now: clock)
            require(!privateText.body.contains(a.title) && !privateText.body.contains(b.title), "group privacy hides titles")
            let single = groupedDelivery.receipts.values.first { $0.keys.count == 1 }!
            require(single.category == SystemNotificationTransport.category(join: true, snooze: true), "single keeps Join and Snooze")
            groupedStore.tick(); await settle()
            require(groupedTransport.submissions.count == 2, "accepted groups do not repeat")
            var agenda = 0
            var openedLink = false
            groupedStore.openNotificationAgenda = { agenda += 1 }
            groupedStore.openNotificationLink = { _ in openedLink = true }
            groupedDelivery.receive(id: banner.id, action: "choose")
            require(agenda == 1 && !openedLink, "Choose Meeting opens agenda without joining an arbitrary meeting")
            require(groupedDelivery.receipts.values.contains { $0.id == single.id }, "group action preserves unrelated banner")
            groupedStore.prepareForTermination({})
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
        let wakeRequest = store.beginFullRefresh(subscriptionIDs: [source.id])
        store.commitEvents([runningA]); store.tick(); await settle()
        let beforeSecondSource = system.submissions.count
        store.commitEvents([runningA, runningB]); store.tick(); await settle()
        require(system.submissions.count == beforeSecondSource, "catch-up waits for asynchronous refresh completion")
        store.finishRefresh(fetched: [source], requestID: wakeRequest); await settle()
        require(system.submissions.last?.keys.count == 2 && system.submissions.last?.catchUp == true, "wake groups running meetings")
        let before = system.submissions.count
        store.beginNotificationCatchUp(); store.tick(); await settle()
        require(system.submissions.count == before && fullscreen.isEmpty, "repeated wake does not duplicate catch-up")
        clock = base.addingTimeInterval(1900); store.tick(); await settle()
        require(delivery.receipts.isEmpty, "ended meetings removed from Notification Center")
        store.settings.notifySyncErrors = true
        let failureRequest = store.beginFullRefresh(subscriptionIDs: [source.id])
        store.merge(results: [FetchResult(subscription: source, events: [], error: "Synthetic failure", requestID: failureRequest)])
        store.finishRefresh(fetched: [source], requestID: failureRequest)
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
        let restartRequest = errorRestart.beginFullRefresh(subscriptionIDs: [source.id])
        errorRestart.merge(results: [FetchResult(subscription: source, events: [], error: "Still failing", requestID: restartRequest)])
        errorRestart.finishRefresh(fetched: [source], requestID: restartRequest); await settle()
        require(errorTransport.submissions.isEmpty, "continuous failure stays quiet across restart")
        store.merge(results: [FetchResult(subscription: source, events: [], error: nil, requestID: failureRequest)])
        store.tick()
        store.merge(results: [FetchResult(subscription: source, events: [], error: "New failure", requestID: failureRequest)])
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
            updateGuides.startupHealthAcknowledged(installedUpdate: true)
            previewStore.featureGuides = updateGuides
            let previewUpdates = UpdateController(store: previewStore)
            previewUpdates.windowContent = .installed(version: "1.11.0")
            NotificationPreview.render(UpdateView(controller: previewUpdates), size: NSSize(width: 460, height: 424), name: "update-guide", directory: directory)
            previewDefaults.removePersistentDomain(forName: previewDomain)
            let assistant = SetupAssistantController(isNewProfile: true, settings: AppSettings(), defaults: previewDefaults)
            let previewAlerts = AlertController()
            previewAlerts.store = previewStore
            for step in SetupAssistantState.Step.allCases {
                NotificationPreview.render(SetupAssistantView(assistant: assistant, store: previewStore, alerts: previewAlerts,
                    notifications: previewDelivery, onFinish: {}), size: NSSize(width: 560, height: 430), name: "setup-" + step.rawValue, directory: directory)
                assistant.next()
            }
            assistant.back()
            previewTransport.status.authorization = .allowed
            _ = await previewDelivery.checkPermission()
            NotificationPreview.render(SetupAssistantView(assistant: assistant, store: previewStore, alerts: previewAlerts,
                notifications: previewDelivery, onFinish: {}), size: NSSize(width: 560, height: 430), name: "setup-reminders-enabled", directory: directory)
            NotificationPreview.renderSettings(store: previewStore, alerts: previewAlerts, updates: previewUpdates, directory: directory)
            previewDefaults.removePersistentDomain(forName: previewDomain)
        }
        let deferredGuides = FeatureGuideController()
        let resumedStore = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("guide-resume")), initialState: Persisted())
        resumedStore.featureGuides = deferredGuides
        let resumedUpdater = UpdateController(store: resumedStore)
        resumedUpdater.startupHealthAcknowledged()
        require(deferredGuides.updateIDs == [FeatureGuideCatalog.notificationsID], "unseen guide survives process state restore without install marker")
        if case .features = resumedUpdater.windowContent {} else { require(false, "unseen guide gets a new window after restart") }
        let failureStore = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("guide-failure")), initialState: Persisted())
        failureStore.featureGuides = FeatureGuideController()
        let failureUpdater = UpdateController(store: failureStore)
        failureUpdater.windowContent = .problem(title: "Failure", message: "Keep this error", retry: .check)
        failureUpdater.startupHealthAcknowledged()
        if case .problem = failureUpdater.windowContent {} else { require(false, "pending guide must not replace an active update error") }
        resumedUpdater.updateWindowDidShow()
        store.featureGuides = guides
        updater.updateWindowDidShow()
        updater.dismissWindow()
        let nextGuides = FeatureGuideController()
        nextGuides.startupHealthAcknowledged(installedUpdate: true)
        require(nextGuides.updateIDs.isEmpty, "closed guide does not reappear after next update")
        store.settings.notifySyncErrors = false
        store.settings.notifyUpdates = true
        store.settings.automaticUpdateChecks = true
        system.status.authorization = .allowed
        let release = UpdateManifest(version: "999.0.0", zipURL: URL(string: "https://example.com/update.zip")!, assetSize: 1, publishedAt: Date().addingTimeInterval(-4 * 86400), notes: "Synthetic")
        do {
            let recoveryStore = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("recovery-cache")), initialState: Persisted())
            let recovery = UpdateController(store: recoveryStore)
            recovery.applyDecision(.available(release), userInitiated: true)
            recovery.stagedVersion = release.version
            recovery.stagedRoot = root.appendingPathComponent("missing-stage")
            recovery.state.pendingInstallVersion = release.version
            var terminated = false
            recovery.onTerminateForUpdate = { terminated = true }
            recovery.install()
            require(!terminated && recovery.stagedVersion == nil && recovery.state.pendingInstallVersion == nil, "missing staging re-prepares without starting an install or retaining marker")

            let timeoutRoot = root.appendingPathComponent("helper-timeout")
            try! FileManager.default.createDirectory(at: timeoutRoot, withIntermediateDirectories: true)
            let token = UUID()
            var cancelledQuit = false
            recovery.onCancelUpdateTermination = { cancelledQuit = true; recoveryStore.cancelTermination() }
            recoveryStore.prepareForTermination {}
            recovery.installAttempt = token
            recovery.stagedRoot = timeoutRoot
            recovery.stagedVersion = release.version
            recovery.state.pendingInstallVersion = release.version
            recovery.installHelperExited(attempt: UUID(), status: 1)
            require(recovery.state.pendingInstallVersion != nil, "stale helper completion cannot clear a newer attempt")
            require(UpdateInstaller.spawnHelper(bundlePath: root.appendingPathComponent("unused.app").path,
                stagedAppPath: timeoutRoot.appendingPathComponent("extracted/now.app").path,
                backupPath: root.appendingPathComponent("unused-backup.app").path,
                releasesURL: "https://example.invalid", extraEnv: ["NOW_SMOKE_POLL_TIMEOUT": "1"],
                onExit: { status in Task { @MainActor in recovery.installHelperExited(attempt: token, status: status) } }), "timeout helper launches")
            for _ in 0..<50 where recovery.installAttempt != nil { try? await Task.sleep(nanoseconds: 100_000_000) }
            require(cancelledQuit && recovery.installAttempt == nil && recovery.stagedVersion == nil && recovery.state.pendingInstallVersion == nil,
                    "real helper timeout clears staged state and persisted install marker")
            let persistedRecovery = UserDefaults.standard.data(forKey: UpdateController.stateKey).flatMap { try? JSONDecoder().decode(UpdateState.self, from: $0) }
            require(persistedRecovery != nil && persistedRecovery?.pendingInstallVersion == nil, "timeout clears the durable marker as well as memory")
            require(!FileManager.default.fileExists(atPath: timeoutRoot.path), "timeout helper removed its staging")
            if case .problem(_, _, .preparation) = recovery.windowContent {} else { require(false, "timeout exposes recoverable preparation error") }
        }
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
        updater.skipVersion(release.version)
        require(updater.available == nil && updater.stagedVersion == nil && updater.windowContent == nil,
                "skip clears menu offer, staging and window")
        require(!delivery.receipts.values.contains { $0.updateVersion == release.version }, "skip removes update notification")
        let savedSkip = UserDefaults.standard.data(forKey: AppStore.storageKey).flatMap { try? JSONDecoder().decode(Persisted.self, from: $0) }
        require(savedSkip?.settings.skippedUpdateVersion == release.version, "skip persists across restart")
        let automatic = UpdateLogic.decide(manifest: release, currentVersion: "1.0.0", skipped: store.settings.skippedUpdateVersion, now: Date(), minAge: 86400)
        if case .skippedVersion = automatic {} else { require(false, "automatic check suppresses skipped version") }
        let manual = UpdateLogic.decide(manifest: release, currentVersion: "1.0.0", skipped: store.settings.skippedUpdateVersion, now: Date(), minAge: 0, userInitiated: true)
        updater.applyDecision(manual, userInitiated: true)
        if case .available = updater.windowContent {} else { require(false, "manual check reopens skipped version") }
        require(store.settings.skippedUpdateVersion == release.version, "manual check preserves automatic skip preference")
        updater.dismissWindow()
        let updateRestart = UpdateController(store: store)
        updateRestart.applyDecision(.available(release), userInitiated: false)
        store.tick(); await settle()
        require(system.submissions.count == priorUpdates + 1, "update notification marker survives restart and dismissal")
        var nextRelease = release
        nextRelease.version = "999.1.0"
        let newerDecision = UpdateLogic.decide(manifest: nextRelease, currentVersion: "1.0.0", skipped: store.settings.skippedUpdateVersion, now: Date(), minAge: 86400)
        if case .available = newerDecision {} else { require(false, "skipping does not suppress newer releases") }
        updateRestart.applyDecision(newerDecision, userInitiated: false)
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
        let setupDomain = "now-setup-tests-" + UUID().uuidString
        let setupDefaults = UserDefaults(suiteName: setupDomain)!
        defer { setupDefaults.removePersistentDomain(forName: setupDomain) }
        let assistant = SetupAssistantController(isNewProfile: true, settings: AppSettings(), defaults: setupDefaults)
        let unchanged = store.settings
        assistant.draft.leadSeconds = 90
        assistant.next(); assistant.next()
        require(store.settings == unchanged, "assistant draft does not alter live settings")
        let resumed = SetupAssistantController(isNewProfile: false, settings: AppSettings(), defaults: setupDefaults)
        require(resumed.pending && resumed.state.step == .ready && resumed.draft.leadSeconds == 90, "assistant resumes draft and current step after restart")
        let unsupported = await resumed.complete(store: store, permission: { true }, probe: { .failure(.processListUnavailable) })
        require(!unsupported && resumed.state.step == .reminders && store.settings == unchanged, "assistant capability failure leaves settings unchanged and returns to context")
        resumed.draft.inMeetingDelivery = .normal
        resumed.next()
        var permissionWait: CheckedContinuation<Bool, Never>?
        let pendingSetup = Task { await resumed.complete(store: store, permission: {
            await withCheckedContinuation { permissionWait = $0 }
        }, probe: { .success([]) }) }
        await settle()
        resumed.cancelPendingWork()
        permissionWait!.resume(returning: true)
        let cancelled = await pendingSetup.value
        require(!cancelled && resumed.pending && store.settings == unchanged, "assistant closing during validation cancels commit")
        let finished = await resumed.complete(store: store, permission: { true }, probe: { .success([]) })
        require(finished && !resumed.pending && store.settings.leadSeconds == 90, "assistant completes and applies selected reminder timing")
        let completedSetup = SetupAssistantController(isNewProfile: false, settings: store.settings, defaults: setupDefaults)
        require(!completedSetup.pending, "completed assistant never restarts on later launches")
        setupDefaults.removePersistentDomain(forName: setupDomain)
        let noPermission = SetupAssistantController(isNewProfile: true, settings: AppSettings(), defaults: setupDefaults)
        noPermission.next(); noPermission.next()
        let finishedWithoutPermission = await noPermission.complete(store: store, permission: { false }, probe: { fatalError("disabled notifications must not probe meeting detection") })
        require(finishedWithoutPermission && !store.settings.usesNotifications && store.settings.reminderDelivery == .fullscreen,
                "assistant can finish without enabling notifications, with all notification routes disabled")
        // Notification body clicks resolve live details for linked, linkless, and grouped meetings.
        var details: [MeetingEvent] = []
        var agendaOpened = false
        store.openNotificationMeetings = { details = $0 }
        store.openNotificationAgenda = { agendaOpened = true }
        store.settings.reminderDelivery = .notification
        clock = base
        let detailOne = meeting("detail-one")
        let detailTwo = meeting("detail-two", link: URL(string: "https://zoom.us/j/123456789"))
        store.commitEvents([detailOne, detailTwo])
        for selected in [[detailOne], [detailTwo], [detailOne, detailTwo]] {
            let item = ReminderNotification(id: UUID().uuidString, keys: selected.map { NotificationLogic.key($0.id) },
                fingerprints: selected.map(NotificationLogic.fingerprint), expires: base.addingTimeInterval(1800),
                catchUp: selected.count > 1, title: "Test", body: "Test", category: "", sound: false)
            delivery.onResponse?(item, UNNotificationDefaultActionIdentifier)
            require(details.map(\.id) == selected.map(\.id) && !agendaOpened, "notification body opens matching meeting details without agenda/settings")
        }
        // Old batches and repeated wakes must never consume a newer cutoff.
        store.resume()
        clock = base
        store.settings.inMeetingDelivery = .normal
        for mode in [CatchUpDelivery.notification, .skip] {
            store.settings.reminderDelivery = .fullscreen
            store.settings.catchUpDelivery = mode
            store.commitEvents([])
            let oldBatch = store.beginFullRefresh(subscriptionIDs: [source.id])
            store.beginNotificationCatchUp()
            store.finishRefresh(fetched: [source], requestID: oldBatch)
            let firstWakeBatch = store.beginFullRefresh(subscriptionIDs: [source.id])
            store.beginNotificationCatchUp() // A second wake queues another full batch.
            store.finishRefresh(fetched: [source], requestID: firstWakeBatch)
            let latestBatch = store.beginFullRefresh(subscriptionIDs: [source.id])
            let discovered = meeting("review-wake-\(mode)", start: -120)
            store.commitEvents([discovered])
            let beforeCatchUp = system.submissions.count
            store.tick(); await settle()
            require(!fullscreen.contains(discovered.id) && system.submissions.count == beforeCatchUp,
                    "new wake discovery never goes fullscreen or notifies before its batch finishes")
            store.finishRefresh(fetched: [source], requestID: latestBatch); await settle()
            require(!fullscreen.contains(discovered.id), "old completions preserve notification/skip route")
            require(system.submissions.count == beforeCatchUp + (mode == .notification ? 1 : 0),
                    "latest batch releases catch-up notification or retains skip")
            let upcoming = meeting("review-after-cutoff-\(mode)", start: 30)
            store.commitEvents([upcoming]); store.tick(); await settle()
            require(fullscreen.contains(upcoming.id), "post-cutoff meeting retains normal delivery")
        }

        // Exercise the actual pendingRefresh chain without a network request.
        let queuedSource = CalendarSubscription(name: "Queued", url: "invalid", colorIndex: 0)
        var queuedSettings = AppSettings(); queuedSettings.catchUpDelivery = .notification
        let queued = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("queued")),
            initialState: Persisted(subscriptions: [queuedSource], settings: queuedSettings))
        queued.now = { clock }
        await queued.restoreCachedEvents()
        let queuedTransport = FakeNotifications()
        let queuedDelivery = ReminderNotificationController(transport: queuedTransport)
        queuedDelivery.now = { clock }; queued.connectNotifications(queuedDelivery)
        var queuedFullscreen = 0; queued.onAlert = { queuedFullscreen += $0.count }
        let oldQueued = queued.beginFullRefresh(subscriptionIDs: [queuedSource.id])
        queued.beginNotificationCatchUp(); queued.refresh() // Sets pendingRefresh.
        queued.finishRefresh(fetched: [queuedSource], requestID: oldQueued) // Starts queued full batch.
        let queuedEvent = MeetingEvent(uid: "queued", title: "Queued discovery", start: base.addingTimeInterval(-30),
            end: base.addingTimeInterval(1800), location: nil, notes: nil, link: nil,
            calendarID: queuedSource.id, calendarName: queuedSource.name, colorIndex: 0)
        queued.commitEvents([queuedEvent]); queued.tick()
        await settle()
        require(queuedFullscreen == 0 && queuedTransport.submissions.count == 1 && queuedTransport.submissions[0].catchUp,
                "pendingRefresh hands catch-up ownership to the queued full batch")
        // Restore the first store's synthetic profile for the restart assertions below.
        store.settings.reminderDelivery = .fullscreen

        // Explicit joins only acknowledge within the lead window; both choices survive reload.
        store.settings.catchUpDelivery = .normal
        let early = meeting("review-early", start: 86400, end: 90000)
        let dueJoin = meeting("review-due-join", start: 86400, end: 90000)
        store.commitEvents([early, dueJoin]); store.joinedMeeting(early)
        clock = dueJoin.start.addingTimeInterval(-TimeInterval(store.settings.leadSeconds))
        store.joinedMeeting(dueJoin)
        let joinRestart = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("join-restart")))
        joinRestart.now = { clock }
        await joinRestart.restoreCachedEvents()
        joinRestart.commitEvents([early, dueJoin])
        var joinAlerts: [String] = []
        joinRestart.onAlert = { joinAlerts += $0.map(\.id) }
        joinRestart.tick(); await settle()
        require(joinAlerts == [early.id], "early join preserves reminder; lead-window join remains handled after restart")

        clock = base
        store.settings.reminderDelivery = .notification
        store.settings.snoozeSeconds = 60
        for deferred in [false, true] {
            let event = meeting("review-paused-snooze-\(deferred)", start: 0)
            store.commitEvents([event]); store.tick(); await settle()
            let receipt = delivery.receipts.values.first { $0.keys.contains(NotificationLogic.key(event.id)) }!
            let request = deferred ? store.beginFullRefresh(subscriptionIDs: [source.id]) : nil
            if deferred { delivery.receive(id: receipt.id, action: "snooze") }
            store.pauseIndefinitely()
            if !deferred { delivery.receive(id: receipt.id, action: "snooze") }
            if let request { store.finishRefresh(fetched: [source], requestID: request) }
            let countBefore = system.submissions.count
            clock = base.addingTimeInterval(61)
            store.tick(); await settle()
            require(system.submissions.count == countBefore, "paused explicit snooze remains quiet")
            store.resume(); store.tick(); await settle()
            require(system.submissions.count == countBefore + 1, "direct/deferred Snooze re-arms through pause")
            clock = base
        }
        let unsafeSnooze = meeting("review-unsafe-snooze", start: 0, end: 2)
        store.commitEvents([unsafeSnooze]); store.tick(); await settle()
        let unsafeReceipt = delivery.receipts.values.first { $0.keys.contains(NotificationLogic.key(unsafeSnooze.id)) }!
        store.pauseIndefinitely(); details = []
        delivery.receive(id: unsafeReceipt.id, action: "snooze")
        require(details.map(\.id) == [unsafeSnooze.id], "paused Snooze with no safe duration opens current details")
        store.resume()
        let endedSnooze = meeting("review-ended-snooze", start: 0, end: 90)
        store.commitEvents([endedSnooze]); store.tick(); await settle()
        let endedReceipt = delivery.receipts.values.first { $0.keys.contains(NotificationLogic.key(endedSnooze.id)) }!
        store.pauseIndefinitely(); delivery.receive(id: endedReceipt.id, action: "snooze")
        clock = base.addingTimeInterval(91)
        let beforeEnded = system.submissions.count
        store.resume(); store.tick(); await settle()
        require(system.submissions.count == beforeEnded, "snooze never re-fires after meeting end")
        clock = base
        let pair = [meeting("review-pair-a", start: 0), meeting("review-pair-b", start: 0)]
        store.commitEvents(pair)
        let pairBefore = system.submissions.count
        store.tick(); await settle()
        require(system.submissions.count == pairBefore + 1 && system.submissions.last?.keys.count == 2 && system.submissions.last?.category == SystemNotificationTransport.chooseMeetingCategory,
                "ordinary simultaneous reminders share a chooser banner")

        // Startup detection retries with persisted intent, bounded backoff and cancellation.
        let probe = ScriptedMeetingProbe()
        let probeSource = MeetingActivitySource(snapshot: { await probe.snapshot() })
        var probeSettings = AppSettings(); probeSettings.inMeetingDelivery = .notification
        let probeStore = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("probe")),
            initialState: Persisted(subscriptions: [], settings: probeSettings), meetingActivitySource: probeSource)
        probeStore.now = { clock }
        probeStore.start(); await settle()
        require(probe.calls == 1 && probeStore.settings.inMeetingDelivery == .notification && probeStore.meetingDetectionError != nil,
                "startup failure preserves notification preference and exposes error")
        let savedProbeSettings = UserDefaults.standard.data(forKey: AppStore.storageKey)!
        require((try? JSONDecoder().decode(Persisted.self, from: savedProbeSettings))?.settings.inMeetingDelivery == .notification,
                "failed startup retains choice on disk")
        clock = base.addingTimeInterval(4); probeStore.retryMeetingDetection(); await settle()
        require(probe.calls == 1, "capability retry respects initial backoff")
        clock = base.addingTimeInterval(5); probeStore.retryMeetingDetection(); await settle()
        require(probe.calls == 2, "capability retries automatically at deadline")
        clock = base.addingTimeInterval(14); probeStore.retryMeetingDetection(); await settle()
        require(probe.calls == 2, "second failure doubles backoff")
        probe.result = .success([])
        probeStore.refreshMeetingActivityAfterWake(); await settle()
        require(probe.calls == 3 && probeStore.meetingDetectionError == nil && probeStore.settings.inMeetingDelivery == .notification,
                "wake retries early and successful capability restores detection")
        probeStore.setInMeetingDelivery(.normal)
        probe.result = .failure(.inputStateUnavailable)
        probeStore.setInMeetingDelivery(.suppress); await settle()
        require(probeStore.settings.inMeetingDelivery == .normal, "failed fresh opt-in leaves delivery unchanged")
        let freshCalls = probe.calls
        clock = base.addingTimeInterval(1000); probeStore.retryMeetingDetection(force: true); await settle()
        require(probe.calls == freshCalls, "failed fresh opt-in does not silently retry enablement")
        probeStore.settings.inMeetingDelivery = .suppress
        probeStore.setInMeetingDelivery(.suppress); await settle()
        for _ in 0..<8 { probeStore.retryMeetingDetection(force: true); await settle() }
        let cappedCalls = probe.calls
        clock = clock.addingTimeInterval(299); probeStore.retryMeetingDetection(); await settle()
        require(probe.calls == cappedCalls, "repeated failures wait for capped backoff")
        clock = clock.addingTimeInterval(1); probeStore.retryMeetingDetection(); await settle()
        require(probe.calls == cappedCalls + 1, "retry backoff caps at five minutes")
        probe.result = .success([])
        probeStore.appBecameActive(); await settle()
        require(probe.calls == cappedCalls + 2 && probeStore.meetingDetectionError == nil,
                "activation recovers saved suppression before retry deadline")
        probeStore.setInMeetingDelivery(.normal)
        probe.hold = true
        probeStore.setInMeetingDelivery(.notification); await settle()
        probeStore.setInMeetingDelivery(.normal)
        probe.waiting!.resume(returning: .success([])); probe.waiting = nil
        await settle()
        require(probeStore.settings.inMeetingDelivery == .normal && !probeStore.meetingDetectionChecking,
                "disabled setting rejects late successful capability callback")
        probe.hold = false
        probeStore.settings.inMeetingDelivery = .suppress
        probe.result = .failure(.processListUnavailable)
        probeStore.setInMeetingDelivery(.suppress); await settle()
        let unsupportedCalls = probe.calls
        probeStore.retryMeetingDetection(force: true); await settle()
        require(probe.calls == unsupportedCalls && probeStore.settings.inMeetingDelivery == .suppress && probeStore.meetingDetectionAvailable == false,
                "unsupported capability preserves preference without endless retries")
        probeStore.setInMeetingDelivery(.normal)
        await lifecycleTests(root: root)
        print("NOTIFICATION SMOKE OK — async races, permission recovery, routing, privacy, snooze, restart, wake grouping, cleanup, update notices, feature migration")
    }
}
