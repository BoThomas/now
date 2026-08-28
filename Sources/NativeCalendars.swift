import Foundation
import AppKit
import EventKit

/// Plain-value snapshot of an `EKCalendar` for UI/persistence handoff — no EventKit
/// objects cross into SwiftUI state or persisted models.
struct NativeCalendarInfo: Identifiable, Equatable {
    let ekIdentifier: String
    let title: String
    let sourceTitle: String
    let colorHex: String
    var id: String { ekIdentifier }
}

/// Owns the app's single `EKEventStore` (a second instance makes `calendars(for:)`
/// return nothing on recent macOS — see docs/plans/native-calendar-integration.md).
/// Main-thread use only, like the rest of AppStore. Reading is never prompted for
/// outside `requestAccess()`, so instantiating this at launch is TCC-silent.
@MainActor
final class NativeCalendarSource {
    let store = EKEventStore()

    /// Fired on the main thread whenever EventKit reports any change to the calendar
    /// database — move/edit/cancel in Calendar.app lands here within milliseconds.
    var onStoreChange: (() -> Void)?
    private var changeObserver: NSObjectProtocol?

    init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            // The notification queue is `.main`, so we are on the main thread.
            MainActor.assumeIsolated {
                self?.onStoreChange?()
            }
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    var isAuthorized: Bool {
        if #available(macOS 14.0, *) {
            return authorizationStatus() == .fullAccess
        }
        return authorizationStatus() == .authorized
    }

    func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// macOS 14+ has no read-only tier: `requestFullAccessToEvents` is the only way to
    /// read. The legacy `requestAccess(to:)` would silently grant **write-only** when
    /// called on macOS 14, so branch on availability.
    func requestAccess() async -> Bool {
        if #available(macOS 14.0, *) {
            return (try? await store.requestFullAccessToEvents()) ?? false
        }
        return await withCheckedContinuation { continuation in
            store.requestAccess(to: .event) { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Every calendar EventKit can see (iCloud, Google/Exchange via CalDAV, local,
    /// subscribed), minus the synthetic Birthdays calendar. Empty unless authorized.
    func availableCalendarInfos() -> [NativeCalendarInfo] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event)
            .filter { $0.type != .birthday }
            .sorted {
                let a = ($0.source?.title ?? "", $0.title)
                let b = ($1.source?.title ?? "", $1.title)
                return a < b
            }
            .map { calendar in
                NativeCalendarInfo(
                    ekIdentifier: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source?.title ?? "",
                    colorHex: Palette.hexString(from: NSColor(cgColor: calendar.cgColor) ?? Palette.nsColor(0))
                )
            }
    }

    /// Materializes each occurrence of recurring events itself, so no RRULE handling is
    /// needed here: detached/changed occurrences come through with their own start date
    /// and share the `eventIdentifier`, matching `MeetingEvent.id = (calendarID, uid, start)`.
    ///
    /// Window semantics match the ICS path exactly: an event is kept when its
    /// START lies within `−6h … +14d` of `now` and it has not already ended at
    /// windowStart (long-running events that began before the window are not
    /// resurrected from ICS either).
    ///
    /// Latency budget (see review checklist): `events(matching:)` is synchronous
    /// on the main thread by design. Budget: < 50 ms warm, < 500 ms cold
    /// (right after launch or wake) for a representative multi-account store.
    /// `--native` prints per-calendar timings to check this.
    func fetchEvents(calendars: [NativeCalendar], skipDeclined: Bool, now: Date) -> [MeetingEvent] {
        guard isAuthorized, !calendars.isEmpty else { return [] }
        let windowStart = now.addingTimeInterval(-6 * 3600)
        let windowEnd = now.addingTimeInterval(14 * 86400)
        let ekCalendars = calendars.compactMap { store.calendar(withIdentifier: $0.ekIdentifier) }
        guard !ekCalendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: ekCalendars)
        var result: [MeetingEvent] = []
        for ekEvent in store.events(matching: predicate) {
            guard ekEvent.startDate >= windowStart, ekEvent.startDate <= windowEnd, ekEvent.endDate > windowStart else { continue }
            guard let ekCalendar = ekEvent.calendar else { continue }
            guard let native = calendars.first(where: { $0.ekIdentifier == ekCalendar.calendarIdentifier }) else { continue }
            guard let event = Self.meetingEvent(from: ekEvent, calendarTitle: ekCalendar.title, native: native, skipDeclined: skipDeclined) else { continue }
            result.append(event)
        }
        return result.sorted { ($0.start, $0.title, $0.uid) < ($1.start, $1.title, $1.uid) }
    }

    /// EKEvent has no public conference property — the join link lives in
    /// `url`/`location`/`notes`. Synthesize a `ParsedEvent` so `LinkExtractor`
    /// (priority order, host heuristics) is reused unchanged from the ICS path.
    nonisolated static func meetingEvent(from ekEvent: EKEvent, calendarTitle: String, native: NativeCalendar, skipDeclined: Bool) -> MeetingEvent? {
        if ekEvent.isAllDay { return nil }
        if ekEvent.status == .canceled { return nil }
        if skipDeclined, isDeclined(ekEvent) { return nil }
        guard let identifier = ekEvent.eventIdentifier, !identifier.isEmpty else { return nil }
        let parsed = parsedEvent(
            uid: identifier,
            title: ekEvent.title ?? "",
            location: ekEvent.location,
            notes: ekEvent.notes,
            url: ekEvent.url?.absoluteString,
            start: ekEvent.startDate,
            end: ekEvent.endDate
        )
        let hex = native.colorHex.isEmpty ? Palette.hex(for: native.colorIndex) : native.colorHex
        return MeetingEvent(
            uid: parsed.uid,
            title: parsed.title,
            start: ekEvent.startDate,
            end: ekEvent.endDate,
            location: ekEvent.location,
            notes: ekEvent.notes,
            link: LinkExtractor.link(from: parsed),
            calendarID: native.id,
            calendarName: calendarTitle,
            colorIndex: native.colorIndex,
            colorHex: hex
        )
    }

    nonisolated static func isDeclined(_ event: EKEvent) -> Bool {
        guard let attendees = event.attendees else { return false }
        return attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined }
    }

    /// Pure function over plain values (EventKit-free) so the native→ICS mapping is
    /// unit-testable in the selftest, which must run without any TCC prompting.
    nonisolated static func parsedEvent(uid: String, title: String, location: String?, notes: String?, url: String?, start: Date, end: Date) -> ParsedEvent {
        ParsedEvent(
            uid: uid,
            title: title,
            location: location,
            description: notes,
            altDescription: nil,
            conference: nil,
            url: url,
            attach: nil,
            status: "",
            isAllDay: false,
            dtStart: start,
            tz: nil,
            durationSeconds: max(60, end.timeIntervalSince(start)),
            rrule: nil,
            exdates: [],
            recurrenceID: nil
        )
    }
}
