import Foundation
import NowCore

extension NotificationSmoke {
    @MainActor static func guideSubmissionTests(root: URL) async {
        func require(_ value: Bool, _ message: String) {
            if !value { fatalError("Guide submission: " + message) }
        }
        let liveProbe = ScriptedMeetingProbe()
        let store = AppStore(eventCache: CalendarEventCache(directory: root.appendingPathComponent("guide-submission")),
                             initialState: Persisted(),
                             meetingActivitySource: MeetingActivitySource(snapshot: { await liveProbe.snapshot() }))
        defer { store.prepareForTermination({}) }
        let submission = NotificationGuideSubmission()
        let probe = ScriptedMeetingProbe()
        var initialChoices = NotificationSetupChoices(settings: store.settings, supportsMeetings: true)
        initialChoices.duringMeetings = true
        let choices = initialChoices
        let original = store.settings
        let saved = AppPreferences.standard.data(forKey: AppStore.storageKey)

        let failed = await submission.apply(choices, to: store, permission: { true }, probe: { await probe.snapshot() })
        require(!failed && submission.problem != nil && !submission.busy, "failed probe keeps the page retryable")
        require(store.settings == original && AppPreferences.standard.data(forKey: AppStore.storageKey) == saved,
                "failed fresh opt-in leaves memory and persisted settings unchanged")
        require(liveProbe.calls == 0, "failed validation never starts live detection")

        probe.hold = true
        let cancelled = Task { @MainActor in
            await submission.apply(choices, to: store, permission: { true }, probe: { await probe.snapshot() })
        }
        await settle()
        require(submission.busy && store.settings == original, "validation does not commit while suspended")
        let duplicate = await submission.apply(choices, to: store, permission: { true }, probe: { fatalError("duplicate probe") })
        require(!duplicate, "double navigation cannot submit twice")
        submission.cancel()
        probe.waiting!.resume(returning: .success([])); probe.waiting = nil
        let cancelledResult = await cancelled.value
        require(!cancelledResult && store.settings == original, "closing the guide rejects a late successful probe")

        let changed = Task { @MainActor in
            await submission.apply(choices, to: store, permission: { true }, probe: { await probe.snapshot() })
        }
        await settle()
        store.settings.leadSeconds = original.leadSeconds + 1
        let externallyChanged = store.settings
        probe.waiting!.resume(returning: .success([])); probe.waiting = nil
        let changedResult = await changed.value
        require(!changedResult && store.settings == externallyChanged && submission.problem != nil,
                "concurrent Settings edit is preserved and prevents stale navigation")
        store.settings = original

        let permission = FakeNotifications()
        let revoked = Task { @MainActor in
            await submission.apply(choices, to: store, permission: { permission.status.canSubmit }, probe: { await probe.snapshot() })
        }
        await settle()
        permission.status.authorization = .denied
        probe.waiting!.resume(returning: .success([])); probe.waiting = nil
        let revokedResult = await revoked.value
        require(!revokedResult && store.settings == original, "permission revoked during validation prevents the commit")

        probe.hold = false
        probe.result = .success([])
        let success = await submission.apply(choices, to: store, permission: { true }, probe: { await probe.snapshot() })
        require(success && submission.problem == nil && !submission.busy && store.settings.inMeetingDelivery == .notification,
                "successful validation commits and allows navigation")
        require(liveProbe.calls == 0, "validated owners prevent a second opt-in probe after the commit")
        let persisted = AppPreferences.standard.data(forKey: AppStore.storageKey)!
        require((try? AppModelCoding.decoder().decode(Persisted.self, from: persisted))?.settings == store.settings,
                "successful choices persist")
        let unchanged = await submission.apply(choices, to: store, permission: { true }, probe: { fatalError("unchanged mode must preserve detection") })
        require(unchanged, "unrelated guide settings preserve existing detection ownership")

        var disabledChoices = choices
        disabledChoices.duringMeetings = false; disabledChoices.catchUp = false
        disabledChoices.updates = false; disabledChoices.syncErrors = false
        let disabled = await submission.apply(disabledChoices, to: store, permission: { fatalError("disabling needs no permission") },
                                               probe: { fatalError("disabling needs no detection") })
        require(disabled && !store.settings.usesNotifications, "explicitly disabling notifications needs neither permission nor a probe")
        print("GUIDE SUBMISSION OK — failure, cancellation, concurrent edits, permission loss, duplicate actions, validated commit")
    }
}
