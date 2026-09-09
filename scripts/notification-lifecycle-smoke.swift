import Foundation
import UserNotifications

/// Production AppStore/controller, fake transport, isolated preferences and cache.
@MainActor
private final class LifecycleFixture {
    let base = Date()
    var clock: Date
    let source = CalendarSubscription(name: "Lifecycle", url: "invalid", colorIndex: 0)
    let second = CalendarSubscription(name: "Peer", url: "invalid-peer", colorIndex: 1)
    let store: AppStore
    let transport = FakeNotifications()
    let controller: ReminderNotificationController
    let domain = "now-lifecycle-" + UUID().uuidString
    let defaults: UserDefaults
    var details: [MeetingEvent] = []
    var agenda = 0

    init(root: URL) {
        clock = base
        defaults = UserDefaults(suiteName: domain)!
        var settings = AppSettings()
        settings.reminderDelivery = .notification
        store = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent(UUID().uuidString)),
                         initialState: Persisted(subscriptions: [source, second], settings: settings))
        controller = ReminderNotificationController(transport: transport, defaults: defaults)
        store.now = { [weak self] in self?.clock ?? Date() }
        controller.now = { [weak self] in self?.clock ?? Date() }
        store.connectNotifications(controller)
        store.openNotificationMeetings = { [weak self] in self?.details = $0 }
        store.openNotificationAgenda = { [weak self] in self?.agenda += 1 }
    }
    func prepare() async {
        await store.restoreCachedEvents()
        let request = store.beginFullRefresh(subscriptionIDs: [source.id, second.id])
        store.finishRefresh(fetched: [source, second], requestID: request)
    }
    func event(_ uid: String, title: String = "Original", start: TimeInterval = 120, end: TimeInterval = 1800,
               location: String? = nil, link: URL? = nil, muted: Bool = false) -> MeetingEvent {
        MeetingEvent(uid: uid, title: title, start: base.addingTimeInterval(start), end: base.addingTimeInterval(end),
                     location: location, notes: nil, link: link, calendarID: source.id, calendarName: source.name,
                     colorIndex: 0, isMuted: muted, notificationIdentity: "single:" + uid)
    }
    func commit(_ events: [MeetingEvent], observed: Bool = true) {
        store.commitEvents(events, observedCalendarIDs: observed ? [source.id] : [])
    }
    func tick() async { store.tick(); await NotificationSmoke.settle() }
    func cleanup() { defaults.removePersistentDomain(forName: domain) }
}

extension NotificationSmoke {
    @MainActor static func lifecycleTests(root: URL) async {
        func require(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { print("FAIL lifecycle: " + message); exit(1) }
        }
        do {
            let f = LifecycleFixture(root: root); defer { f.cleanup() }
            await f.prepare()
            f.store.settings.catchUpDelivery = .skip
            let event = f.event("snooze", start: -120)
            f.commit([event]); f.store.snooze([event.id: f.base.addingTimeInterval(60)])
            f.store.beginNotificationCatchUp()
            f.clock = f.base.addingTimeInterval(60)
            await f.tick()
            let id = f.controller.receipts.keys.first!
            for _ in 0..<3 { await f.tick() }
            require(f.controller.receipts[id] != nil && f.transport.submissions.count == 1, "snooze survives consumption of its deadline under catch-up Skip")
            f.controller.receive(id: id, action: "snooze")
            f.clock = f.clock.addingTimeInterval(60)
            await f.tick()
            require(f.transport.submissions.count == 2, "retained snooze action still re-arms exactly once")
        }
        do {
            let f = LifecycleFixture(root: root); defer { f.cleanup() }
            await f.prepare()
            f.store.settings.catchUpDelivery = .notification
            let short = f.event("short", start: -120, end: 10), long = f.event("long", start: -120)
            f.commit([short, long]); f.store.beginNotificationCatchUp()
            let request = f.store.beginFullRefresh(subscriptionIDs: [f.source.id, f.second.id])
            f.store.finishRefresh(fetched: [f.source, f.second], requestID: request)
            await settle()
            let id = f.controller.receipts.keys.first!
            f.clock = f.base.addingTimeInterval(11); await f.tick()
            require(f.controller.receipts[id]?.keys == [NotificationLogic.eventKey(long)] && f.transport.submissions.count == 1,
                    "group retains remaining member without another banner")
            f.controller.receive(id: id, action: UNNotificationDefaultActionIdentifier)
            require(f.details.map(\.id) == [long.id], "outdated group content resolves only the still-running member")
        }
        do {
            let f = LifecycleFixture(root: root); defer { f.cleanup() }
            await f.prepare()
            f.store.settings.catchUpDelivery = .notification
            let a = f.event("join-a", start: -120), b = f.event("join-b", start: -120)
            f.commit([a, b]); f.store.beginNotificationCatchUp()
            let request = f.store.beginFullRefresh(subscriptionIDs: [f.source.id, f.second.id])
            f.store.finishRefresh(fetched: [f.source, f.second], requestID: request); await settle()
            let id = f.controller.receipts.keys.first!
            f.store.joinedMeeting(a); await f.tick()
            require(f.controller.receipts[id]?.keys == [NotificationLogic.eventKey(b)] && f.transport.submissions.count == 1,
                    "joining one group member preserves the other")
            f.commit([f.event("join-b", start: -120, muted: true)]); await f.tick()
            require(f.controller.receipts.isEmpty, "last member muting removes the group")
        }
        do {
            let f = LifecycleFixture(root: root); defer { f.cleanup() }
            await f.prepare(); f.store.settings.notifySyncErrors = true
            let request = f.store.beginFullRefresh(subscriptionIDs: [f.source.id, f.second.id])
            f.store.merge(results: [f.source, f.second].map { FetchResult(subscription: $0, events: [], error: "offline", requestID: request) })
            f.store.finishRefresh(fetched: [f.source, f.second], requestID: request)
            f.clock = f.base.addingTimeInterval(300); await f.tick()
            let id = f.controller.receipts.keys.first!
            f.store.merge(results: [FetchResult(subscription: f.source, events: [], error: nil, requestID: request)])
            await f.tick()
            require(f.controller.receipts[id] != nil && f.transport.submissions.count == 1, "sync group survives partial recovery without re-notifying")
            f.clock = f.base.addingTimeInterval(2 * 86400); await f.tick()
            require(f.controller.receipts[id] != nil && f.transport.submissions.count == 1, "ongoing sync episode survives original submission expiry without re-notifying")
            f.store.merge(results: [FetchResult(subscription: f.second, events: [], error: nil, requestID: request)])
            await f.tick(); require(f.controller.receipts.isEmpty, "fully recovered sync group removed")
        }
        do {
            let f = LifecycleFixture(root: root); defer { f.cleanup() }
            await f.prepare()
            let original = f.event("edit")
            f.commit([original]); await f.tick()
            let oldID = f.controller.receipts.keys.first!
            let request = f.store.beginFullRefresh(subscriptionIDs: [f.source.id, f.second.id])
            f.commit([f.event("edit", title: "Intermediate")]); await f.tick()
            f.commit([f.event("edit", title: "Final", start: 240, end: 2000, location: "Room", link: URL(string: "https://example.com/new"))]); await f.tick()
            require(f.transport.submissions.count == 1, "edits within a full batch coalesce")
            f.store.finishRefresh(fetched: [f.source, f.second], requestID: request); await settle()
            let replacement = f.transport.submissions.last!
            require(f.transport.submissions.count == 2 && replacement.title == "Meeting updated" && !replacement.sound,
                    "time/title/location/link edit produces one silent labeled replacement")
            require(f.transport.removed.contains(oldID) && replacement.body.contains("Final"), "old removed and latest details displayed")
            await f.tick(); require(f.transport.submissions.count == 2, "replacement does not repeat")
            f.controller.receive(id: replacement.id, action: UNNotificationDismissActionIdentifier)
            f.commit([f.event("edit", title: "After dismissal", start: 250, end: 2000)]); await f.tick()
            require(f.transport.submissions.count == 2, "dismissal survives further time edits")
        }
        do {
            let f = LifecycleFixture(root: root); defer { f.cleanup() }
            await f.prepare()
            let event = f.event("restore")
            f.commit([event]); await f.tick()
            let oldID = f.controller.receipts.keys.first!
            f.commit([]); await f.tick()
            require(f.controller.receipts[oldID]?.hidden == true && f.transport.removed.contains(oldID), "first omission removes visible content but retains restoration intent")
            f.commit([event]); await f.tick()
            require(f.transport.submissions.last?.title == "Meeting reminder restored" && f.transport.submissions.last?.sound == false,
                    "return produces a silent restoration notice")
            f.commit([]); f.commit([]); await f.tick()
            require(f.controller.receipts.isEmpty, "confirmed absence retires restoration intent")
        }
        do {
            let f = LifecycleFixture(root: root); defer { f.cleanup() }
            await f.prepare(); f.store.settings.hideNotificationDetails = true
            f.commit([f.event("private", title: "Secret")]); await f.tick()
            f.commit([f.event("private", title: "More secret", location: "Secret room")]); await f.tick()
            let update = f.transport.submissions.last!
            require(update.title == "Meeting updated" && !update.body.lowercased().contains("secret") && !update.sound, "replacement respects privacy")
            let event = f.store.events[0]
            f.store.snooze([event.id: f.base.addingTimeInterval(500)])
            f.commit([f.event("private", title: "Changed while snoozed", start: 240)]); await f.tick()
            require(f.transport.submissions.count == 2, "editing a snoozed occurrence preserves the deadline")
            f.clock = f.base.addingTimeInterval(500); await f.tick()
            require(f.transport.submissions.count == 3, "moved occurrence snooze fires at original deadline")
        }
        do {
            let f = LifecycleFixture(root: root); defer { f.cleanup() }
            await f.prepare()
            f.commit([f.event("retry")]); await f.tick()
            f.transport.fail = true
            f.commit([f.event("retry", title: "Changed")]); await f.tick()
            require(f.controller.receipts.values.first?.hidden == true, "failed replacement retains hidden retry intent")
            f.transport.fail = false
            f.clock = f.base.addingTimeInterval(61); await f.tick()
            require(f.transport.submissions.count == 3 && f.controller.receipts.values.first?.hidden == false,
                    "failed replacement retries successfully after backoff")
            let acceptedID = f.controller.receipts.keys.first!
            f.transport.hold = true
            f.commit([f.event("retry", title: "Another edit")]); await settle()
            let staleID = f.transport.submissions.last!.id
            f.controller.receive(id: acceptedID, action: UNNotificationDismissActionIdentifier)
            f.transport.release(); await settle(); await f.tick()
            require(f.controller.receipts.isEmpty && f.transport.removed.contains(staleID), "late dismissal of replaced banner cancels pending replacement")
        }
        do {
            let f = LifecycleFixture(root: root); defer { f.cleanup() }
            await f.prepare()
            f.commit([f.event("race")]); await f.tick()
            f.transport.hold = true
            f.commit([f.event("race", title: "First edit")]); await settle()
            let staleID = f.transport.submissions.last!.id
            f.commit([f.event("race", title: "Second edit")]); await f.tick(); await f.tick()
            f.transport.release(); await settle(); await f.tick()
            require(f.controller.receipts.count == 1 && f.controller.receipts.values.first?.body.contains("Second edit") == true
                    && f.transport.removed.contains(staleID), "late old add cannot remove or acknowledge newest replacement")
        }
        do {
            let f = LifecycleFixture(root: root); defer { f.cleanup() }
            await f.prepare()
            f.commit([f.event("joined")]); await f.tick()
            f.commit([f.event("joined", title: "Updated")]); await f.tick()
            let ids = f.transport.submissions.map(\.id)
            f.store.joinedMeeting(f.store.events[0])
            for id in ids { f.controller.receive(id: id, action: "snooze") }
            f.commit([f.event("joined", title: "After Join", start: 240)]); await f.tick()
            require(f.controller.receipts.isEmpty && f.transport.submissions.count == 2, "Join retires old aliases and survives time edits")
        }
        do {
            let f = LifecycleFixture(root: root); defer { f.cleanup() }
            await f.prepare()
            f.commit([f.event("interrupted")]); await f.tick()
            var unconfirmed = f.controller.receipts.values.first!
            unconfirmed.accepted = false
            f.defaults.set(try! JSONEncoder().encode([unconfirmed.id: unconfirmed]), forKey: "local.tboch.now.notification-receipts.v1")
            let recovery = ReminderNotificationController(transport: f.transport, defaults: f.defaults)
            recovery.now = { f.clock }; f.store.connectNotifications(recovery)
            await f.tick()
            require(f.transport.submissions.count == 2 && recovery.receipts.values.first?.accepted == true,
                    "interrupted meeting submission retries after receipt reload")
            var sync = unconfirmed; sync.id = "now.sync.interrupted"; sync.sync = true
            f.defaults.set(try! JSONEncoder().encode([sync.id: sync]), forKey: "local.tboch.now.notification-receipts.v1")
            let diagnostics = ReminderNotificationController(transport: f.transport, defaults: f.defaults)
            diagnostics.deferRestoredReconciliation = { true }
            diagnostics.reconcile()
            require(diagnostics.receipts.isEmpty, "interrupted diagnostic add releases its reservation even during calendar startup")
        }
        // Saved receipt before startup refresh: test response on both sides of cleanup.
        for missing in [false, true] {
            let f = LifecycleFixture(root: root); defer { f.cleanup() }
            await f.prepare()
            let event = f.event("cold")
            f.commit([event]); await f.tick()
            let id = f.controller.receipts.keys.first!
            let cold = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent(UUID().uuidString)))
            cold.now = { f.clock }
            let transport = FakeNotifications()
            let controller = ReminderNotificationController(transport: transport, defaults: f.defaults)
            controller.now = { f.clock }; cold.connectNotifications(controller)
            var agenda = 0, details = 0
            cold.openNotificationAgenda = { agenda += 1 }; cold.openNotificationMeetings = { details += $0.count }
            let request = cold.beginFullRefresh(subscriptionIDs: [f.source.id, f.second.id])
            await cold.restoreCachedEvents(); cold.tick(); await settle()
            require(controller.receipts[id] != nil, "cold receipt survives empty cache before response arrives")
            if !missing { controller.receive(id: id, action: UNNotificationDefaultActionIdentifier) }
            cold.commitEvents(missing ? [] : [event], observedCalendarIDs: [f.source.id])
            cold.finishRefresh(fetched: [f.source, f.second], requestID: request); await settle()
            if missing { controller.receive(id: id, action: UNNotificationDefaultActionIdentifier) }
            require(missing ? agenda == 1 : details == 1, "cold action resolves current meeting or menu agenda")
            controller.receive(id: id, action: UNNotificationDefaultActionIdentifier)
            require(agenda + details == 1, "cold callback is consumed exactly once")
        }
        do {
            let probe = ScriptedMeetingProbe()
            let source = MeetingActivitySource(snapshot: { await probe.snapshot() })
            var settings = AppSettings(); settings.inMeetingDelivery = .suppress
            let store = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent(UUID().uuidString)),
                                 initialState: Persisted(settings: settings), meetingActivitySource: source)
            var time = Date(); store.now = { time }
            store.start(); await settle()
            var choices = NotificationSetupChoices(settings: store.settings)
            choices.duringMeetings = false; choices.catchUp = true
            store.applyNotificationSetup(choices, owners: nil)
            let calls = probe.calls; probe.result = .success([])
            time = time.addingTimeInterval(6); store.retryMeetingDetection(); await settle()
            require(probe.calls == calls + 1 && store.meetingDetectionError == nil, "guide preserves scheduled retry")
            probe.hold = true
            store.setInMeetingDelivery(.suppress); await settle()
            store.applyNotificationSetup(choices, owners: nil)
            require(store.meetingDetectionChecking, "guide preserves in-flight capability check")
            probe.waiting!.resume(returning: .success([])); probe.waiting = nil; await settle()
            require(!store.meetingDetectionChecking && store.meetingDetectionError == nil, "preserved capability response is accepted")
            store.setInMeetingDelivery(.normal)
            store.prepareForTermination({})
        }
        print("NOTIFICATION LIFECYCLE OK — snooze lifetime, group retention, edits/restoration, explicit actions, retries/races, cold actions, detection recovery")
    }
}
