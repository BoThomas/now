import Foundation
import NowCore

extension CoreTests {
    static func modelDecoding(_ check: inout Check) throws {
        let legacy = Data("{\"name\":\"Legacy\",\"url\":\"https://example.invalid\",\"colorIndex\":-7}".utf8)
        let first = ModelDecoding.decoder(calendarColor: { $0 == -7 ? "#123456" : "#000000" })
        let second = ModelDecoding.decoder(calendarColor: { _ in "#abcdef" })
        check.expect(try first.decode(CalendarSubscription.self, from: legacy).colorHex == "#123456", "legacy color receives the original index")
        check.expect(try second.decode(CalendarSubscription.self, from: legacy).colorHex == "#abcdef", "second decoder has its own palette")
        check.expect(try first.decode(CalendarSubscription.self, from: legacy).colorHex == "#123456", "decoder policies never replace each other")
        check.expect(try JSONDecoder().decode(CalendarSubscription.self, from: legacy).colorHex == "", "unconfigured core decoder retains unresolved color sentinel")
        for (field, expected) in [("null", "#123456"), ("\"\"", ""), ("\"#fedcba\"", "#fedcba")] {
            let json = "{\"subscriptions\":[{\"name\":\"Legacy\",\"url\":\"https://example.invalid\",\"colorIndex\":-7,\"colorHex\":\(field)}]}"
            let profile = try first.decode(Persisted.self, from: Data(json.utf8))
            check.expect(profile.subscriptions.first?.colorHex == expected, "nested missing/null versus explicit color semantics")
        }
        let native = try first.decode(NativeCalendar.self, from: Data("{\"ekIdentifier\":\"opaque\",\"name\":\"Native\"}".utf8))
        check.expect(native.colorHex == "" && native.ekIdentifier == "opaque", "native metadata preserves its own empty-color default")

        let defaults = try first.decode(AppSettings.self, from: Data("{}".utf8))
        check.expect(defaults == AppSettings() && defaults.leadSeconds == 300 && defaults.snoozeSeconds == 0, "base settings retain pre-setup defaults")
        for sound in ["Basso", "Blow", "Bottle", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"] {
            let decoded = try first.decode(AppSettings.self, from: Data("{\"soundName\":\"\(sound)\"}".utf8))
            check.expect(decoded.soundName == sound, "saved sound identifier survives: \(sound)")
        }
        let invalidSound = try first.decode(AppSettings.self, from: Data("{\"soundName\":\"Unknown\"}".utf8))
        check.expect(invalidSound.soundName == "Hero", "unknown saved sound keeps legacy fallback")
        let conflict = try first.decode(AppSettings.self, from: Data("{\"leadSeconds\":0,\"snoozeSeconds\":0,\"notifyDuringMeetings\":true,\"suppressRemindersDuringMeetings\":true,\"notifyOnCatchUp\":true,\"skipMeetingsOnCatchUp\":true}".utf8))
        check.expect(conflict.snoozeSeconds == 60 && conflict.inMeetingDelivery == .notification && conflict.catchUpDelivery == .skip,
                     "conflicting reminder settings retain precedence and at-start snooze fallback")
        let bounded = try first.decode(AppSettings.self, from: Data("{\"leadSeconds\":9223372036854775807,\"refreshMinutes\":-9223372036854775808,\"elapsedStartMinutes\":-9223372036854775808,\"snoozeSeconds\":9223372036854775807}".utf8))
        check.expect(bounded.leadSeconds == 7200 && bounded.snoozeSeconds == 7200 && bounded.refreshMinutes == 5 && bounded.elapsedStartMinutes == -1,
                     "extreme settings normalize without overflow")
        var timing = AppSettings()
        timing.leadSeconds = 0
        check.expect(timing.snoozeSeconds == 60, "editing lead time preserves snooze invariant")
        timing.snoozeSeconds = 37
        check.expect(AppSettings.snoozeDurations(including: timing.snoozeSeconds).contains(37), "custom snooze remains exact")
    }

    static func modelRecovery(_ check: inout Check) throws {
        let sharedID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let nativeID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        let profile = """
        {"subscriptions":[
          {"id":"\(sharedID)","name":"Kept","url":"https://example.invalid","titleFilters":[{"pattern":" Standup "},{"pattern":42}]},
          {"id":"\(sharedID)","name":"Duplicate","url":"https://example.invalid/duplicate"},
          {"name":"Broken","url":42},
          {"name":"Bad color","url":"https://example.invalid","colorHex":42}],
         "nativeCalendars":[
          {"id":"\(sharedID)","name":"Duplicate native","ekIdentifier":"one"},
          {"id":"\(nativeID)","name":"Native kept","ekIdentifier":"two"}],
         "settings":{"leadSeconds":"bad","soundEnabled":false,"skippedUpdateVersion":null},
         "pausedUntil":null}
        """
        let audit = PreferenceDecoding()
        let decoder = ModelDecoding.decoder(calendarColor: { _ in "#112233" })
        decoder.userInfo[PreferenceDecoding.key] = audit
        let restored = try decoder.decode(Persisted.self, from: Data(profile.utf8))
        check.expect(audit.recovered, "lossy decoding records damage across the module boundary")
        check.expect(restored.subscriptions.map(\.name) == ["Kept"] && restored.nativeCalendars.map(\.name) == ["Native kept"],
                     "bad records and cross-source duplicate UUIDs do not discard valid siblings")
        check.expect(restored.subscriptions.first?.titleFilters.map(\.pattern) == ["Standup"], "bad title-rule sibling is salvaged and normalized")
        check.expect(restored.subscriptions.first?.colorHex == "#112233", "palette migration survives partial recovery")
        check.expect(restored.settings.leadSeconds == 300 && !restored.settings.soundEnabled && restored.pausedUntil == nil,
                     "bad scalar falls back while valid setting and optional null survive")
        let cleanAudit = PreferenceDecoding()
        decoder.userInfo[PreferenceDecoding.key] = cleanAudit
        _ = try decoder.decode(Persisted.self, from: Data("{\"settings\":{\"skippedUpdateVersion\":null},\"pausedUntil\":null}".utf8))
        check.expect(!cleanAudit.recovered, "missing migration fields and optional nulls are not damage")
        _ = try decoder.decode(Persisted.self, from: Data("{\"subscriptions\":null}".utf8))
        check.expect(cleanAudit.recovered, "null required collection is damage")
        let cleanAgain = PreferenceDecoding()
        decoder.userInfo[PreferenceDecoding.key] = cleanAgain
        _ = try decoder.decode(Persisted.self, from: Data("{}".utf8))
        check.expect(!cleanAgain.recovered && audit.recovered, "recovery audits remain decoder-local")
    }

    static func modelEncoding(_ check: inout Check) throws {
        // Literal pre-extraction wire shape: decoding then encoding must not add
        // palette providers, recovery audits or presentation-only properties.
        let json = """
        {"subscriptions":[{"id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","name":"Calendar","url":"https://example.invalid/feed","colorIndex":2,"colorHex":"#abcdef","isEnabled":true,"titleFilters":[{"id":"CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC","pattern":"Standup","mode":"exact"}]}],
         "nativeCalendars":[{"id":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","ekIdentifier":"opaque","name":"Native","colorIndex":0,"colorHex":"","isEnabled":false,"titleFilters":[]}],
         "settings":{"leadSeconds":300,"refreshMinutes":15,"soundEnabled":true,"soundName":"Hero","showMenuBarCountdown":true,"menuMeetingLimit":5,"launchAtLogin":false,"elapsedStartMinutes":10,"skipDeclined":true,"snoozeSeconds":0,"automaticUpdateChecks":true,"suppressRemindersDuringMeetings":false,"includeBrowserMeetings":false,"reminderDelivery":"fullscreen","notifyDuringMeetings":false,"notifyOnCatchUp":false,"skipMeetingsOnCatchUp":false,"hideNotificationDetails":false,"notifySyncErrors":false,"notifyUpdates":false},
         "pausedUntil":800000000}
        """
        let data = Data(json.utf8)
        let decoder = ModelDecoding.decoder(calendarColor: { _ in "#000000" })
        let restored = try decoder.decode(Persisted.self, from: data)
        let encoded = try JSONEncoder().encode(restored)
        let expected = try JSONSerialization.jsonObject(with: data) as! NSDictionary
        let actual = try JSONSerialization.jsonObject(with: encoded) as! NSDictionary
        check.expect(actual == expected, "saved profile wire fields and values match pre-extraction shape")
        let reread = try decoder.decode(Persisted.self, from: encoded)
        check.expect(reread.subscriptions == restored.subscriptions && reread.nativeCalendars == restored.nativeCalendars
                     && reread.settings == restored.settings && reread.pausedUntil == restored.pausedUntil, "profile round trip retains all persisted values")
    }

    static func titleFilters(_ check: inout Check) {
        let rules = TitleFilterRule.normalized([
            TitleFilterRule(pattern: " Standup "), TitleFilterRule(pattern: "standup"),
            TitleFilterRule(pattern: "(?i)review", mode: .regex), TitleFilterRule(pattern: "[", mode: .regex),
            TitleFilterRule(pattern: " ")
        ])
        check.expect(rules.map(\.pattern) == ["Standup", "(?i)review", "["], "normalization trims/deduplicates but retains invalid regex for editing")
        let matcher = TitleFilterMatcher(rules: rules)
        check.expect(matcher.matches(title: " STANDUP ") && !matcher.matches(title: "Standup follow-up"), "exact matching remains case-insensitive whole-title")
        check.expect(matcher.matches(title: "Design REVIEW 👩🏽‍💻"), "regex search handles Unicode ranges and explicit case flag")
        check.expect(!matcher.matches(title: "["), "invalid regex is inert")
        check.expect(TitleFilterRule(pattern: String(repeating: "a", count: 501), mode: .regex).isValid == false, "regex length cap retained")
        check.expect(TitleFilterRule(pattern: String(repeating: "a", count: 501)).isValid, "exact titles remain uncapped")
        let many = TitleFilterRule.normalized((0..<60).map { TitleFilterRule(pattern: "Rule \($0)") })
        check.expect(many.count == 50 && many.last?.pattern == "Rule 49", "rule-count cap preserves input ordering")
        var subscription = CalendarSubscription(name: "Calendar", url: "https://example.invalid", colorIndex: 0, colorHex: "#123456")
        subscription.titleFilters = rules
        let original = modelEvent(calendarID: subscription.id, title: "Standup")
        let muted = TitleFilterMatcher.applying(to: [original], subscriptions: [subscription])
        check.expect(muted.count == 1 && muted[0].isMuted && muted[0].id == original.id && muted[0].colorHex == original.colorHex,
                     "filtering changes mute state without deleting events or changing identity/presentation")
        check.expect(!TitleFilterMatcher.applying(to: muted)[0].isMuted, "removing calendar rules clears derived mute state")
        var native = NativeCalendar(ekIdentifier: "opaque", name: "Native")
        native.titleFilters = [TitleFilterRule(pattern: "Standup")]
        let nativeEvent = modelEvent(calendarID: native.id, title: "Standup")
        check.expect(TitleFilterMatcher.applying(to: [nativeEvent], nativeCalendars: [native])[0].isMuted, "native metadata shares matching policy")
        let removed = TitleFilterRule.removing(ids: [rules[0].id], from: rules)
        check.expect(removed.map(\.id) == Array(rules.dropFirst()).map(\.id), "rule removal preserves sibling IDs/order")
    }

    static func modelEvent(calendarID: UUID, title: String = "Meeting", start: Date = Date(timeIntervalSince1970: 1_800_000_000), identity: String? = nil) -> MeetingEvent {
        MeetingEvent(uid: "uid", title: title, start: start, end: start.addingTimeInterval(3600), location: nil,
                     notes: nil, link: nil, calendarID: calendarID, calendarName: "Calendar", colorIndex: 0,
                     colorHex: "#123456", notificationIdentity: identity)
    }

    static func meetingIdentity(_ check: inout Check) {
        let id = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let plain = modelEvent(calendarID: id)
        let first = modelEvent(calendarID: id, identity: "ics:3:uid:1800000000.0")
        let second = modelEvent(calendarID: id, identity: "ics:3:uid:1800086400.0")
        check.expect(plain.id == "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA-uid-1800000000", "legacy agenda identity bytes retained")
        check.expect(first.id == plain.id + "-occurrence:ics:3:uid:1800000000.0" && first.id != second.id, "coincident moved siblings retain exact occurrence suffixes")
        let moved = modelEvent(calendarID: id, start: first.start.addingTimeInterval(60), identity: first.notificationIdentity)
        check.expect(moved.id != first.id && moved.notificationIdentity == first.notificationIdentity, "reschedule changes agenda identity but retains notification anchor")
        check.expect(modelEvent(calendarID: id, identity: "ics:3:uid:single").id == plain.id, "single occurrence retains legacy agenda ID")
        check.expect(modelEvent(calendarID: id, identity: "native:opaque:1800000000.0").id.hasSuffix("-occurrence:native:opaque:1800000000.0"), "native anchor follows existing identity rule")
        check.expect(modelEvent(calendarID: id, identity: "other:opaque").id == plain.id, "unknown identity prefix retains legacy behavior")
    }
}
