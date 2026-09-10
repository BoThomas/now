import Foundation

extension SelfTest {
    static func notificationTests(_ c: inout Checker) {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var setup = SetupAssistantState(isNewProfile: true, settings: AppSettings(), supportsMeetings: true)
        c.expect(setup.draft.leadSeconds == 60 && setup.draft.snoozeSeconds == 0, "assistant: new-user timing defaults to one minute and just in time")
        c.expect(!setup.completed && setup.step == .welcome && setup.draft.notifyDuringMeetings && setup.draft.notifyOnCatchUp && setup.draft.notifyUpdates && setup.draft.notifySyncErrors, "assistant: new user starts with recommended notification draft, including sync problems")
        c.expect(setup.draft.launchAtLogin == AppSettings().launchAtLogin && setup.draft.refreshMinutes == AppSettings().refreshMinutes, "assistant: general defaults untouched")
        let existingSetup = SetupAssistantState(isNewProfile: false, settings: AppSettings(), supportsMeetings: true)
        c.expect(existingSetup.completed && !existingSetup.draft.notifySyncErrors, "assistant: existing empty profiles retain their sync-notification choice and skip setup")
        setup.next(); c.expect(setup.step == .reminders, "assistant: welcome precedes reminder options")
        setup.next(); c.expect(setup.step == .ready && setup.steps.count == 3, "assistant: three-screen flow ends after combined reminders")
        setup.back(); c.expect(setup.step == .reminders, "assistant: back revisits combined reminder screen")
        let disabled = SetupAssistantState.effective(setup.draft, notificationsAllowed: false)
        c.expect(!disabled.usesNotifications && disabled.reminderDelivery == .fullscreen && disabled.inMeetingDelivery == .normal, "assistant: permission off disables every notification route")
        c.expect(SetupAssistantState.effective(setup.draft, notificationsAllowed: true) == setup.draft && setup.draft.notifyDuringMeetings, "assistant: later grant restores draft choices without losing them")
        let allowedSettings = SetupAssistantState.applying(SetupAssistantState.effective(setup.draft, notificationsAllowed: true), to: AppSettings())
        c.expect(allowedSettings.notifySyncErrors, "assistant: allowed new setup enables sync-problem notifications")
        c.expect(!SetupAssistantState.applying(disabled, to: allowedSettings).notifySyncErrors, "assistant: denied setup clears sync-problem notifications even when current settings enabled them")
        let legacyDraft = #"{"completed":false,"step":"context","draft":{}}"#.data(using: .utf8)!
        c.expect((try? JSONDecoder().decode(SetupAssistantState.self, from: legacyDraft))?.step == .reminders, "assistant: old context step migrates to combined reminders")
        var current = AppSettings()
        current.refreshMinutes = 30; current.launchAtLogin = true; current.automaticUpdateChecks = false
        current.showMenuBarCountdown = false; current.elapsedStartMinutes = 60
        var draft = AppSettings(); draft.leadSeconds = 90; draft.snoozeSeconds = 45; draft.hideNotificationDetails = true
        let applied = SetupAssistantState.applying(draft, to: current)
        c.expect(applied.leadSeconds == 90 && applied.snoozeSeconds == current.snoozeSeconds && applied.hideNotificationDetails, "assistant: selected reminder choices applied")
        c.expect(applied.refreshMinutes == 30 && applied.launchAtLogin == draft.launchAtLogin && applied.automaticUpdateChecks == draft.automaticUpdateChecks && !applied.showMenuBarCountdown && applied.elapsedStartMinutes == 60, "assistant: selected startup/update choices apply while other general settings stay unchanged")
        let encodedSetup = try? JSONEncoder().encode(setup)
        c.expect(encodedSetup.flatMap { try? JSONDecoder().decode(SetupAssistantState.self, from: $0) } == setup, "assistant: draft and step survive restart")
        for lead in [0, 60, 300] {
            for snooze in [0, 45, 7200] {
                var previewSettings = AppSettings()
                previewSettings.leadSeconds = lead
                previewSettings.snoozeSeconds = snooze == 0 && lead == 0 ? 60 : snooze
                let sample = AlertController.previewEvent(at: now, settings: previewSettings)
                c.expect(sample.start == now.addingTimeInterval(TimeInterval(lead)), "preview: sample respects reminder lead time")
                let options = AlertController.snoozeOptions(events: [sample], now: now, customSeconds: previewSettings.snoozeSeconds)
                let plan = AlertController.primarySnoozePlan(options: options, defaultSeconds: previewSettings.snoozeSeconds)
                c.expect(plan == (previewSettings.snoozeSeconds == 0 ? .atStart : .duration(previewSettings.snoozeSeconds)), "preview: selected snooze fits sample meeting")
            }
        }
        let catalog = FeatureGuideCatalog.entries
        var guides = FeatureGuideState()
        c.expect(guides.acknowledge(catalog: catalog, installedUpdate: true) == [FeatureGuideCatalog.notificationsID], "guide: legacy user sees feature on crossing its introduction")
        guides.pendingPresentation.removeAll() // The guide window became visible.
        for _ in 0..<3 {
            c.expect(guides.acknowledge(catalog: catalog, installedUpdate: true).isEmpty, "guide: subsequent updates never repeat introduction")
        }
        let futureGuide = FeatureGuideDefinition(id: "future-feature", content: .information(title: "Future", message: "Explanation"))
        c.expect(guides.acknowledge(catalog: catalog + [futureGuide], installedUpdate: true) == [futureGuide.id], "guide: future update introduces only its new feature")
        guides.pendingPresentation.removeAll()
        var skipped = FeatureGuideState()
        c.expect(skipped.acknowledge(catalog: catalog + [futureGuide], installedUpdate: true).count == 2, "guide: skipped releases collect all new features")
        skipped.pendingPresentation.removeAll() // Both guides were displayed.
        _ = skipped.acknowledge(catalog: catalog, installedUpdate: true)
        c.expect(skipped.acknowledge(catalog: catalog + [futureGuide], installedUpdate: true).isEmpty, "guide: downgrade preserves feature history")
        var manual = FeatureGuideState()
        c.expect(manual.acknowledge(catalog: catalog, installedUpdate: false, existingProfile: true) == [FeatureGuideCatalog.notificationsID], "guide: manual upgrade discovers unseen features without updater marker")
        manual.pendingPresentation.removeAll()
        c.expect(manual.acknowledge(catalog: catalog, installedUpdate: false, existingProfile: true).isEmpty, "guide: manual upgrade guide does not repeat")
        c.expect(manual.acknowledge(catalog: catalog + [futureGuide], installedUpdate: false, existingProfile: true) == [futureGuide.id], "guide: later manual upgrade discovers only new features")
        var initial = FeatureGuideState()
        c.expect(initial.acknowledge(catalog: catalog + [futureGuide], installedUpdate: false).isEmpty, "guide: first-run assistant replaces inline setup cards")
        c.expect(initial.acknowledge(catalog: catalog, installedUpdate: true).isEmpty, "guide: later update does not repeat pending initial setup")
        let savedGuides = try? JSONEncoder().encode(guides)
        c.expect(savedGuides.flatMap { try? JSONDecoder().decode(FeatureGuideState.self, from: $0) } == guides, "guide: introduction history persists")
        var updateSettings = AppSettings()
        updateSettings.notifyUpdates = true
        var updateState = UpdateState()
        let manifest = UpdateManifest(version: "2.0.0", zipURL: URL(string: "https://example.com/update.zip")!, assetSize: 1, publishedAt: now.addingTimeInterval(-86400), notes: "")
        func shouldNotify(_ state: UpdateState, _ settings: AppSettings, _ current: String = "1.0.0", _ time: Date = now) -> Bool {
            UpdateLogic.shouldNotifyUpdate(manifest: manifest, state: state, settings: settings, currentVersion: current, now: time)
        }
        c.expect(shouldNotify(updateState, updateSettings), "update notice: eligible release")
        c.expect(!shouldNotify(updateState, updateSettings, "2.0.0"), "update notice: installed release removed")
        c.expect(shouldNotify(updateState, updateSettings, "1.0.0", manifest.publishedAt), "update notice: newly published release is immediately eligible")
        c.expect(!shouldNotify(updateState, updateSettings, "1.0.0", manifest.publishedAt.addingTimeInterval(-1)), "update notice: future-dated release stays quiet")
        updateState.lastNotificationVersion = "2.0.0"
        c.expect(!shouldNotify(updateState, updateSettings), "update notice: once per version")
        updateState.lastNotificationVersion = "3.0.0"
        c.expect(!shouldNotify(updateState, updateSettings), "update notice: withdrawn newer release does not re-notify older release")
        updateState.lastNotificationVersion = nil
        updateState.lastNotifiedVersion = "2.0.0"
        c.expect(!shouldNotify(updateState, updateSettings), "update notice: already shown or failed install does not nag")
        updateState.lastNotifiedVersion = nil
        updateSettings.automaticUpdateChecks = false
        c.expect(!shouldNotify(updateState, updateSettings), "update notice: automatic checks off")
        updateSettings.automaticUpdateChecks = true
        updateSettings.notifyUpdates = false
        c.expect(!shouldNotify(updateState, updateSettings), "update notice: opt-in required")
        let oldUpdate = Data(#"{"attemptsToday":2,"attemptsDayStamp":"2026-09-08","lastNotifiedVersion":"1.5"}"#.utf8)
        let restoredUpdate = try? JSONDecoder().decode(UpdateState.self, from: oldUpdate)
        c.expect(restoredUpdate?.attemptsToday == 2 && restoredUpdate?.lastNotifiedVersion == "1.5" && restoredUpdate?.lastNotificationVersion == nil, "update notice: old bookkeeping decodes without losing state")
        var legacySuppression = AppSettings()
        legacySuppression.inMeetingDelivery = .suppress
        c.expect(!NotificationSetupChoices(settings: legacySuppression, supportsMeetings: true).duringMeetings, "guide: preserve legacy suppression recommendation")
        c.expect(!NotificationSetupChoices(settings: AppSettings(), supportsMeetings: false).duringMeetings, "guide: unsupported meeting detection not recommended")
        var syncOnly = NotificationSetupChoices(settings: AppSettings(), supportsMeetings: false)
        c.expect(syncOnly.syncErrors, "guide: recommend sync-problem notifications to users configuring notifications for the first time")
        syncOnly.catchUp = false; syncOnly.updates = false
        c.expect(syncOnly.needsPermission, "guide: sync-problem notifications alone require permission")
        syncOnly.syncErrors = false
        c.expect(!syncOnly.needsPermission, "guide: no permission needed when every notification option is off")
        var configuredNotifications = AppSettings()
        configuredNotifications.reminderDelivery = .notification
        c.expect(!NotificationSetupChoices(settings: configuredNotifications).syncErrors, "guide: keep sync-problem alerts off for existing notification users who have them off")
        configuredNotifications.notifySyncErrors = true
        c.expect(NotificationSetupChoices(settings: configuredNotifications).syncErrors, "guide: keep enabled sync-problem alerts selected")
        let legacyGuides = Data(#"{"encountered":["notification-setup-v1"],"pendingSettings":["notification-setup-v1"]}"#.utf8)
        var migratedGuides = try? JSONDecoder().decode(FeatureGuideState.self, from: legacyGuides)
        c.expect(migratedGuides?.acknowledge(catalog: catalog, installedUpdate: true).isEmpty == true,
                 "guide: retired pending cards decode without forgetting encountered history")
        struct LegacyGuideState: Decodable { let encountered: Set<String>; let pendingSettings: Set<String> }
        let downgradeGuide = savedGuides.flatMap { try? JSONDecoder().decode(LegacyGuideState.self, from: $0) }
        c.expect(downgradeGuide?.encountered == guides.encountered && downgradeGuide?.pendingSettings.isEmpty == true,
                 "guide: new encoding preserves history when an older release decodes it")
        var catchUpOwner = CatchUpRefreshTracker()
        catchUpOwner.started(1)
        catchUpOwner.begin()
        c.expect(!catchUpOwner.finish(1) && catchUpOwner.pending, "catch-up: pre-wake batch cannot finalize new session")
        catchUpOwner.started(2)
        catchUpOwner.begin() // Another wake while the replacement batch runs.
        c.expect(!catchUpOwner.finish(2) && catchUpOwner.pending, "catch-up: repeated wake revokes old owner")
        catchUpOwner.started(4) // A targeted generation 3 does not own a full batch.
        c.expect(!catchUpOwner.finish(3) && catchUpOwner.pending, "catch-up: targeted generation cannot clear cutoff")
        c.expect(catchUpOwner.finish(4) && !catchUpOwner.pending && !catchUpOwner.finish(4), "catch-up: latest full batch completes once")
        c.expect(AppStore.emptyAgendaText(configuredCount: 1, enabledCount: 1, isRefreshing: true, hasErrors: false,
                     nativeAccessMissing: false, expiredCache: true) == "Checking calendars…", "expired cache does not obscure active refresh")
        c.expect(AppStore.emptyAgendaText(configuredCount: 1, enabledCount: 1, isRefreshing: false, hasErrors: false,
                     nativeAccessMissing: false, expiredCache: true) == "No upcoming meetings. Some saved calendars need refreshing.", "expired cache message qualifies empty agenda")
        let calendar = UUID()
        func event(_ uid: String = "one", start: TimeInterval = 120, end: TimeInterval = 1800, muted: Bool = false) -> MeetingEvent {
            MeetingEvent(uid: uid, title: "Private title", start: now.addingTimeInterval(start), end: now.addingTimeInterval(end),
                         location: "Secret room", notes: "Private notes", link: URL(string: "https://zoom.us/j/123?pwd=secret"),
                         calendarID: calendar, calendarName: "Secret calendar", colorIndex: 0, isMuted: muted)
        }
        var settings = AppSettings()
        let future = event(), running = event("running", start: -120)
        for (date, expected) in [(future.start.addingTimeInterval(-61), false),
                                 (future.start.addingTimeInterval(-60), true), (future.start, true),
                                 (future.end.addingTimeInterval(-1), true), (future.end, false)] {
            c.expect(AppStore.joinHandlesReminder(future, leadSeconds: 60, now: date) == expected,
                     "join: respects exact lead-window and end boundaries")
        }
        let meeting = MeetingActivity.meeting(.zoom)
        c.expect(NotificationLogic.route(event: future, settings: settings, activity: .unknown, catchUp: false, snoozed: false, now: now) == .fullscreen, "notification: existing default fullscreen")
        settings.reminderDelivery = .notification
        c.expect(NotificationLogic.route(event: future, settings: settings, activity: .unknown, catchUp: false, snoozed: false, now: now) == .notification, "notification: notification mode unknown activity")
        settings.inMeetingDelivery = .suppress
        c.expect(NotificationLogic.route(event: future, settings: settings, activity: meeting, catchUp: false, snoozed: false, now: now) == .deferReminder, "notification: suppression defers before start")
        c.expect(NotificationLogic.route(event: running, settings: settings, activity: meeting, catchUp: true, snoozed: false, now: now) == .handled, "notification: suppression handles started meetings")
        settings.inMeetingDelivery = .notification
        c.expect(NotificationLogic.route(event: running, settings: settings, activity: meeting, catchUp: false, snoozed: false, now: now) == .notification, "notification: in-meeting notification never discarded by suppression")
        settings.inMeetingDelivery = .normal
        settings.reminderDelivery = .fullscreen
        settings.notifyOnCatchUp = true
        c.expect(NotificationLogic.route(event: running, settings: settings, activity: .unknown, catchUp: true, snoozed: false, now: now) == .catchUp, "notification: launch/wake catch-up")
        c.expect(NotificationLogic.route(event: running, settings: settings, activity: .unknown, catchUp: true, snoozed: true, now: now) == .fullscreen, "notification: snoozes retain ordinary delivery on wake")
        c.expect(NotificationLogic.route(event: running, settings: settings, activity: .unknown, catchUp: false, snoozed: false, now: now) == .fullscreen, "notification: ordinary refresh remains ordinary delivery")
        for grouped in [false, true] {
            let text = NotificationLogic.content(events: grouped ? [future, running] : [future], privateDetails: true, catchUp: grouped, now: now)
            let combined = text.title + text.body
            c.expect(!combined.contains("Private") && !combined.contains("Secret") && !combined.contains("zoom") && !combined.contains("pwd"), "notification: private content omits all identifying data")
        }
        settings.catchUpDelivery = .skip
        c.expect(NotificationLogic.route(event: running, settings: settings, activity: .unknown, catchUp: true, snoozed: false, now: now) == .handled, "catch-up: skip handles ongoing meeting")
        c.expect(NotificationLogic.route(event: running, settings: settings, activity: .unknown, catchUp: true, snoozed: true, now: now) == .fullscreen, "catch-up: skip preserves explicit snooze")
        c.expect(NotificationLogic.route(event: running, settings: settings, activity: .unknown, catchUp: false, snoozed: false, now: now) == .fullscreen, "catch-up: skip does not affect ordinary reminders")
        settings.inMeetingDelivery = .notification
        c.expect(NotificationLogic.route(event: running, settings: settings, activity: meeting, catchUp: true, snoozed: false, now: now) == .notification, "catch-up: during-meeting rule retains priority")
        for mode in CatchUpDelivery.allCases {
            var choice = AppSettings(); choice.catchUpDelivery = mode
            let restored = try? JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(choice))
            c.expect(restored?.catchUpDelivery == mode, "catch-up: choice round trips")
        }
        for enabled in [false, true] {
            let legacy = try? JSONDecoder().decode(AppSettings.self, from: Data("{\"notifyOnCatchUp\":\(enabled)}".utf8))
            c.expect(legacy?.catchUpDelivery == (enabled ? .notification : .normal), "catch-up: legacy checkbox preserves behavior")
        }
        let plain = NotificationLogic.content(events: [future], privateDetails: false, catchUp: false, now: now)
        for elapsed: TimeInterval in [-1, 0, 1, 9.999, 10, 60] {
            let instant = future.start.addingTimeInterval(elapsed)
            let atStart = elapsed >= 0 && elapsed < 10
            for privacy in [false, true] {
                for catchUp in [false, true] {
                    let single = NotificationLogic.content(events: [future], privateDetails: privacy, catchUp: catchUp, now: instant)
                    c.expect(single.body.hasPrefix("Starts now") == atStart, "notification: start wording at \(elapsed)")
                    if privacy {
                        c.expect(single.title.contains("starting now") == atStart, "notification: private start wording")
                    }
                    let group = NotificationLogic.content(events: [future, event("same-start")], privateDetails: privacy, catchUp: catchUp, now: instant)
                    c.expect(group.title.contains("starting now") == atStart, "notification: grouped start wording")
                }
            }
        }
        c.expect(plain.title == future.title && !plain.body.contains("secret") && !plain.body.contains("Secret"), "notification: normal content includes only title and timing")
        c.expect(!NotificationPermission(authorization: .denied).canSubmit && NotificationPermission(authorization: .allowed).canSubmit, "notification: permission denial blocks; alerts-disabled can use center")

        var ledger = ReminderLedger()
        ledger.record(future, snooze: now.addingTimeInterval(60))
        let key = NotificationLogic.key(future.id)
        let data = try! JSONEncoder().encode(ledger)
        c.expect(!String(data: data, encoding: .utf8)!.contains("Private") && !String(data: data, encoding: .utf8)!.contains(future.uid + "-"), "notification: ledger stores hashed identity, no meeting content")
        ledger = try! JSONDecoder().decode(ReminderLedger.self, from: data)
        c.expect(ledger.entries[key]?.snooze == now.addingTimeInterval(60), "notification: exact snooze survives restart")
        ledger.reconcile(events: [], enabled: [calendar], observed: [], now: now)
        c.expect(ledger.entries[key] != nil, "notification: asynchronous restore and failures retain acknowledgement")
        ledger.reconcile(events: [], enabled: [calendar], observed: [calendar], now: now)
        c.expect(ledger.entries[key] != nil, "notification: one omission retains acknowledgement")
        ledger.reconcile(events: [future], enabled: [calendar], observed: [calendar], now: now)
        ledger.reconcile(events: [], enabled: [calendar], observed: [calendar], now: now)
        c.expect(ledger.entries[key] != nil, "notification: return resets omission counter")
        ledger.reconcile(events: [], enabled: [calendar], observed: [calendar], now: now)
        c.expect(ledger.entries.isEmpty, "notification: two omissions remove acknowledgement")
        ledger.record(future); ledger.invalidate([calendar])
        c.expect(ledger.entries.isEmpty, "notification: source URL replacement invalidates persisted acknowledgement")
        ledger.record(future); ledger.reconcile(events: [], enabled: [], observed: [], now: now)
        c.expect(ledger.entries.isEmpty, "notification: disabled source invalidates acknowledgement")
        ledger.record(future); ledger.reconcile(events: [future], enabled: [calendar], observed: [], now: future.end)
        c.expect(ledger.entries.isEmpty, "notification: ended acknowledgement expires")

        // Notification identity survives a time edit without merging recurring siblings.
        let sub = CalendarSubscription(name: "Identity", url: "https://example.test/feed", colorIndex: 0)
        let anchor = Date(timeIntervalSince1970: 1_800_000_000)
        func feed(_ start: String, recurring: Bool = false, override: String = "") -> [MeetingEvent] {
            let rule = recurring ? "RRULE:FREQ=DAILY;COUNT=2\n" : ""
            let text = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:identity\nSUMMARY:Meeting\nDTSTART:" + start
                + "\nDURATION:PT1H\n" + rule + "END:VEVENT\n" + override + "END:VCALENDAR\n"
            return ICSBuilder.meetings(fromICS: text, subscription: sub, now: anchor).events
        }
        // 2027-01-15 falls within the injected parser window.
        let original = feed("20270115T100000Z")
        let moved = feed("20270115T110000Z")
        c.expect(original.count == 1 && moved.count == 1, "notification identity: standalone fixture parsed")
        if let first = original.first, let second = moved.first {
            c.expect(first.id != second.id && NotificationLogic.eventKey(first) == NotificationLogic.eventKey(second), "notification identity: time edits preserve notification identity only")
            let stableKey = NotificationLogic.eventKey(first)
            var fullscreen = ReminderLedger()
            fullscreen.record(first)
            fullscreen = try! JSONDecoder().decode(ReminderLedger.self, from: JSONEncoder().encode(fullscreen))
            let rearmed = fullscreen.reconcile(events: [second], enabled: [sub.id], observed: [sub.id], now: anchor,
                                               rearmOnReschedule: [stableKey])
            c.expect(rearmed == [second.id] && fullscreen.entries.isEmpty, "fullscreen ledger: saved start detects reschedule after restart")
            var legacyFullscreen = ReminderLedger()
            legacyFullscreen.entries[stableKey] = ReminderLedger.Entry(calendarID: sub.id, end: first.end)
            legacyFullscreen = try! JSONDecoder().decode(ReminderLedger.self, from: JSONEncoder().encode(legacyFullscreen))
            c.expect(legacyFullscreen.reconcile(events: [second], enabled: [sub.id], observed: [sub.id], now: anchor,
                                               rearmOnReschedule: [stableKey], previousEvents: [first]) == [first.id, second.id],
                     "fullscreen ledger: legacy history can detect live reschedules")
            legacyFullscreen.entries[stableKey] = ReminderLedger.Entry(calendarID: sub.id, end: first.end)
            c.expect(legacyFullscreen.reconcile(events: [first], enabled: [sub.id], observed: [], now: anchor,
                                               rearmOnReschedule: [stableKey]).isEmpty && legacyFullscreen.entries[stableKey]?.start == first.start,
                     "fullscreen ledger: legacy startup baselines the start without repeating handled reminders")
            var saved = ReminderLedger()
            saved.entries[NotificationLogic.key(first.id)] = ReminderLedger.Entry(calendarID: sub.id, end: first.end, snooze: anchor.addingTimeInterval(60))
            saved.reconcile(events: [first], enabled: [sub.id], observed: [], now: anchor)
            saved.reconcile(events: [second], enabled: [sub.id], observed: [sub.id], now: anchor)
            c.expect(saved.entries[NotificationLogic.eventKey(second)]?.snooze == anchor.addingTimeInterval(60), "notification identity: legacy ledger migrates and preserves moved snooze")
            let cached = CachedMeeting(first)
            let restored = try? JSONDecoder().decode(CachedMeeting.self, from: JSONEncoder().encode(cached))
            c.expect(restored?.notificationIdentity == first.notificationIdentity, "notification identity: disk cache retains source occurrence anchor")
        }
        let recurring = feed("20270115T100000Z", recurring: true)
        let detached = feed("20270115T100000Z", recurring: true, override: "BEGIN:VEVENT\nUID:identity\nRECURRENCE-ID:20270115T100000Z\nDTSTART:20270115T120000Z\nDURATION:PT1H\nEND:VEVENT\n")
        c.expect(recurring.count == 2 && detached.count == 2, "notification identity: recurring fixture parsed")
        if recurring.count == 2, detached.count == 2 {
            c.expect(NotificationLogic.eventKey(recurring[0]) == NotificationLogic.eventKey(detached[0]), "notification identity: moved override retains original recurrence anchor")
            c.expect(NotificationLogic.eventKey(recurring[0]) != NotificationLogic.eventKey(recurring[1]), "notification identity: recurring siblings remain independent")
        }

        var tracker = SyncNotificationTracker()
        let other = UUID()
        c.expect(tracker.candidates(failed: [calendar], now: now).isEmpty, "notification: transient failure silent")
        c.expect(tracker.candidates(failed: [calendar], now: now.addingTimeInterval(299)).isEmpty, "notification: failure delay lower boundary")
        c.expect(tracker.candidates(failed: [calendar], now: now.addingTimeInterval(300)) == [calendar], "notification: sustained failure threshold")
        tracker.notified = [calendar]
        c.expect(tracker.candidates(failed: [calendar, other], now: now.addingTimeInterval(301)).isEmpty, "notification: unchanged failure silent and new failure waits")
        c.expect(tracker.candidates(failed: [calendar, other], now: now.addingTimeInterval(601)) == [other], "notification: new source failure independent")
        _ = tracker.candidates(failed: [], now: now.addingTimeInterval(602))
        c.expect(tracker.candidates(failed: [calendar], now: now.addingTimeInterval(603)).isEmpty, "notification: recovery re-arms with full delay")
        let migrated = try! JSONDecoder().decode(AppSettings.self, from: Data("{\"suppressRemindersDuringMeetings\":true}".utf8))
        c.expect(migrated.inMeetingDelivery == .suppress && migrated.reminderDelivery == .fullscreen && !migrated.usesNotifications, "notification: legacy suppression and defaults migrate unchanged")
        settings.notifyDuringMeetings = true; settings.notifySyncErrors = true; settings.hideNotificationDetails = true
        let roundTrip = try! JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        c.expect(roundTrip == settings, "notification: settings round-trip")
    }
}
