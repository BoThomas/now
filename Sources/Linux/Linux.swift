import Foundation
import NowCore

#if os(Linux)
import Glibc
#endif

extension Array {
    /// Bounds-checked access for CLI parsing.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@main enum LinuxMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let mode = arguments.first else {
            print("usage: now-linux selftest | run --root DIR [--refresh N] [--tick N] [--duration N]")
            return
        }
        switch mode {
        case "selftest": await SelfTest.run()
        case "run": await runCLI(Array(arguments.dropFirst()))
        default: print("unknown mode: \(mode)"); exit(2)
        }
    }

    static func runCLI(_ arguments: [String]) async {
        var root: URL?
        var refresh: TimeInterval = 300
        var tick: TimeInterval = 30
        var duration: TimeInterval = 0
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--root": index += 1; root = arguments[safe: index].map { URL(fileURLWithPath: $0) }
            case "--refresh": index += 1; refresh = TimeInterval(arguments[safe: index] ?? "") ?? refresh
            case "--tick": index += 1; tick = TimeInterval(arguments[safe: index] ?? "") ?? tick
            case "--duration": index += 1; duration = TimeInterval(arguments[safe: index] ?? "") ?? duration
            default: break
            }
            index += 1
        }
        guard let root else { print("missing --root"); exit(2) }
        guard let connection = try? DBusConnection.session() else {
            print("no session bus; a desktop session or dbus-run-session is required")
            exit(2)
        }
        connection.startPump()
        let store = LinuxStore(
            root: root, connection: connection,
            logging: { print("now-linux: \($0)") },
            openJoin: { url in openJoin(url) }
        )
        do {
            try await store.startup()
            try await store.run(refreshSeconds: refresh, tickSeconds: tick, duration: duration)
            connection.shutdown()
        } catch {
            print("now-linux: \(error)")
            connection.shutdown()
            exit(1)
        }
    }

    /// The real join opener: xdg-open. Only reachable in run mode; selftest
    /// injects its own sink.
    private static func openJoin(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [url.absoluteString]
        try? process.run()
    }
}

/// Deterministic validation of the Linux shell's D-Bus surface on a private
/// session bus: connection and name ownership, StatusNotifierItem property
/// export, watcher registration, one-shot re-registration across a watcher
/// restart (the Hyprland probe behavior), and notification capability
/// probing with the default-action-only policy read.
enum SelfTest {
    struct Check {
        var count = 0
        var failures: [String] = []
        mutating func expect(_ value: Bool, _ label: String) {
            count += 1
            if !value { failures.append(label) }
        }
    }

    static func instant(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value) ?? Date()
    }

    static func run() async {
        guard ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"] != nil else {
            print("FAIL: no session bus; run via scripts/test-linux.sh (dbus-run-session)")
            exit(1)
        }
        var check = Check()
        do {
            try busBasics(&check)
            try await watcherRegistration(&check)
            try await watcherRestart(&check)
            try notificationCapabilities(&check)
            try menuSurface(&check)
            agendaContent(&check)
            try await storeLoop(&check)
        } catch {
            check.expect(false, "scenario failed: \(error)")
        }
        if !check.failures.isEmpty {
            for failure in check.failures { print("FAIL: \(failure)") }
            exit(1)
        }
        print("LINUX SHELL OK — \(check.count) checks; bus connect, name ownership, watcher registration, property export, restart re-registration, notification capabilities, dbusmenu export/events/revisions, agenda shaping")
    }

    private static func poll(deadline seconds: TimeInterval = 10, _ condition: @Sendable () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    /// Connects two clients (the app and "the rest of the desktop"), owns the
    /// item name, and checks the exported property surface from the outside
    /// connection, exactly like a real watcher would.
    private static func busBasics(_ check: inout Check) throws {
        let app = try DBusConnection.session()
        app.startPump()
        defer { app.shutdown() }
        let desktop = try DBusConnection.session()
        desktop.startPump()
        defer { desktop.shutdown() }
        check.expect(!app.uniqueName.isEmpty && !desktop.uniqueName.isEmpty, "unique bus names assigned")

        let registrar = StatusNotifier.Registrar(connection: app)
        try registrar.registerObject()
        check.expect(true, "item bus name owned and object exported")

        let reply = try desktop.call(
            destination: registrar.serviceName, path: "/StatusNotifierItem",
            interface: "org.freedesktop.DBus.Properties", member: "GetAll",
            arguments: [.string(StatusNotifier.itemInterface)]
        )
        let reader = reply
        let properties = reader.readPropertyDict() ?? [:]
        check.expect(properties["Category"] == "SystemServices", "Category property")
        check.expect(properties["Id"] == "now", "Id property")
        check.expect(properties["Title"] == "now", "Title property")
        check.expect(properties["IconName"]?.isEmpty == false, "IconName property")
        check.expect(properties["ItemIsMenu"] == "true", "ItemIsMenu menu-only configuration")
        check.expect(properties["Menu"] == "/MenuBar", "Menu object path property")
    }

    /// Registers with a synthetic watcher (a separate client, like a real
    /// shell) and asserts exactly one registration, then one more after a
    /// watcher restart.
    private static func watcherRegistration(_ check: inout Check) async throws {
        let app = try DBusConnection.session()
        app.startPump()
        defer { app.shutdown() }
        let desktop = try DBusConnection.session()
        desktop.startPump()
        defer { desktop.shutdown() }
        let watcher = try StatusNotifierFixtures.Watcher(connection: desktop)
        check.expect(true, "fixture watcher owns org.kde.StatusNotifierWatcher")

        let registrar = StatusNotifier.Registrar(connection: app)
        try registrar.registerObject()
        try await registrar.connect(initialTimeout: 5)
        let registered = await poll { watcher.registeredItems.contains(registrar.serviceName) }
        check.expect(registered, "item registered with watcher")
        check.expect(watcher.registeredItems == [registrar.serviceName], "registration carries the item service name")
    }

    private static func watcherRestart(_ check: inout Check) async throws {
        let app = try DBusConnection.session()
        app.startPump()
        defer { app.shutdown() }
        let desktop = try DBusConnection.session()
        desktop.startPump()
        defer { desktop.shutdown() }
        let watcher = try StatusNotifierFixtures.Watcher(connection: desktop)
        let registrar = StatusNotifier.Registrar(connection: app)
        try registrar.registerObject()
        try await registrar.connect(initialTimeout: 5)
        guard await poll({ watcher.count == 1 }) else {
            check.expect(false, "initial registration before restart")
            return
        }
        try watcher.dropAndReown()
        let reregistered = await poll { watcher.count == 2 }
        check.expect(reregistered, "one-shot re-registration after watcher restart")
        try? await Task.sleep(nanoseconds: 500_000_000)
        check.expect(watcher.count == 2, "no registration storm after restart")
    }

    private static func notificationCapabilities(_ check: inout Check) throws {
        let app = try DBusConnection.session()
        app.startPump()
        defer { app.shutdown() }
        let desktop = try DBusConnection.session()
        desktop.startPump()
        defer { desktop.shutdown() }
        let daemon = try StatusNotifierFixtures.Notifications(connection: desktop)
        let capabilities = try StatusNotifier.probeNotifications(connection: app)
        check.expect(capabilities.actions, "actions capability detected")
        check.expect(capabilities.body, "body capability detected")
        check.expect(daemon.queries() == 1, "capability probe queried the daemon once")
        let minimal = StatusNotifier.NotificationCapabilities(capabilities: ["body"])
        check.expect(minimal == .init(capabilities: ["body"]) && !minimal.actions, "default-action-only policy for minimal daemons")
    }

    final class ActionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        func record(_ action: String) {
            lock.lock(); recorded.append(action); lock.unlock()
        }
        var actions: [String] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }
    }

    /// Exports the dbusmenu surface the tray item's Menu property names and
    /// drives it from a second client like a real panel: layout, click
    /// events, revision bumps, and the LayoutUpdated announcement.
    private static func menuSurface(_ check: inout Check) throws {
        let app = try DBusConnection.session()
        app.startPump()
        defer { app.shutdown() }
        let desktop = try DBusConnection.session()
        desktop.startPump()
        defer { desktop.shutdown() }

        let updates = ActionRecorder()
        desktop.addSignalHandler(interface: DBusMenu.interface, member: "LayoutUpdated") { reader in
            guard let revision = reader.readUint32() else { return }
            updates.record(String(revision))
        }

        let publisher = DBusMenu.Publisher(connection: app, path: "/MenuBar")
        let recorder = ActionRecorder()
        publisher.onAction { recorder.record($0) }

        let standup = DBusMenu.Node.item(1, "Join standup", action: "join")
        var root = DBusMenu.Node(id: 0)
        root.children = [standup, .separator(2), .item(3, "Pause reminders", action: "pause")]
        publisher.update(root)

        let shown = try desktop.call(
            destination: app.uniqueName, path: "/MenuBar",
            interface: DBusMenu.interface, member: "AboutToShow", arguments: [.int32(0)]
        )
        check.expect(shown.readBoolean() == true, "AboutToShow answers ready")

        let reply = try desktop.call(
            destination: app.uniqueName, path: "/MenuBar",
            interface: DBusMenu.interface, member: "GetLayout",
            arguments: [.int32(0), .int32(-1), .stringArray([])]
        )
        guard let view = DBusMenu.LayoutView.parse(reply) else {
            check.expect(false, "GetLayout reply parses")
            return
        }
        check.expect(view.revision == 1, "layout revision starts at 1")
        check.expect(view.properties["children-display"] == "submenu", "root carries children-display")
        check.expect(view.childRows.count == 3, "agenda menu rows exported")
        check.expect(view.childRows.first?.label == "Join standup", "agenda labels carry meeting titles")

        _ = try desktop.call(
            destination: app.uniqueName, path: "/MenuBar",
            interface: DBusMenu.interface, member: "Event",
            arguments: [.int32(1), .string("clicked"), .variant(.string("")), .int64(0)]
        )
        var delivered = false
        let start = Date()
        while Date().timeIntervalSince(start) < 5 {
            if recorder.actions == ["join"] { delivered = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        check.expect(delivered, "clicked event delivers the join action")

        root.children.append(.item(4, "Snooze 10 min", action: "snooze"))
        publisher.update(root)

        let updated = try desktop.call(
            destination: app.uniqueName, path: "/MenuBar",
            interface: DBusMenu.interface, member: "GetLayout",
            arguments: [.int32(0), .int32(-1), .stringArray([])]
        )
        guard let second = DBusMenu.LayoutView.parse(updated) else {
            check.expect(false, "updated GetLayout reply parses")
            return
        }
        check.expect(second.revision == 2, "publishing a tree bumps the revision")
        check.expect(second.childRows.count == 4, "updated menu carries the snooze row")
        check.expect(updates.actions.contains("2"), "LayoutUpdated announced the new revision")
    }

    /// Pure agenda shaping from NowCore snapshots: bar countdown focus,
    /// NOW/NEXT/LATER sections, day headers, muted rows, join actions.
    private static func agendaContent(_ check: inout Check) {
        let now = SelfTest.instant("2026-10-01T09:00:00Z")
        let running = MeetingEvent(
            uid: "running", title: "Daily sync", start: SelfTest.instant("2026-10-01T08:55:00Z"),
            end: SelfTest.instant("2026-10-01T09:30:00Z"), location: nil, notes: nil,
            link: URL(string: "https://meet.example.com/daily"), calendarID: UUID(),
            calendarName: "Work", colorIndex: 0, colorHex: "#1f6feb"
        )
        let next = MeetingEvent(
            uid: "next", title: "Design review", start: SelfTest.instant("2026-10-01T10:00:00Z"),
            end: SelfTest.instant("2026-10-01T11:00:00Z"), location: nil, notes: nil,
            link: URL(string: "https://meet.example.com/design"), calendarID: UUID(),
            calendarName: "Work", colorIndex: 1, colorHex: "#8250df"
        )
        var muted = MeetingEvent(
            uid: "muted", title: "Focus block", start: SelfTest.instant("2026-10-01T13:00:00Z"),
            end: SelfTest.instant("2026-10-01T14:00:00Z"), location: nil, notes: nil,
            link: nil, calendarID: UUID(), calendarName: "Work", colorIndex: 2, colorHex: "#2da44e"
        )
        muted.isMuted = true
        let tomorrow = MeetingEvent(
            uid: "tomorrow", title: "Planning", start: SelfTest.instant("2026-10-02T09:00:00Z"),
            end: SelfTest.instant("2026-10-02T09:30:00Z"), location: nil, notes: nil,
            link: nil, calendarID: UUID(), calendarName: "Work", colorIndex: 3, colorHex: "#bf3989"
        )
        let events = [running, next, muted, tomorrow]

        check.expect(AgendaMenu.barTitle(events: events, now: now) == "ends 30m", "bar title counts down a running meeting")
        check.expect(AgendaMenu.barTitle(events: [next], now: now) == "1h", "bar title counts down to the next start")
        check.expect(AgendaMenu.barTitle(events: [], now: now) == "now", "empty agenda bar title")

        let sections = AgendaMenu.sections(events: events, now: now)
        check.expect(sections.map(\.header) == ["NOW", "NEXT", "LATER TODAY", "TOMORROW"], "agenda sections and day headers")
        let nowRows = sections.first?.rows ?? []
        check.expect(nowRows.count == 1 && nowRows[0].label.contains("Daily sync"), "running meeting leads the NOW section")
        check.expect(nowRows[0].action == "join:https://meet.example.com/daily", "running meeting carries its join action")
        let nextRows = sections.first { $0.header == "NEXT" }?.rows ?? []
        check.expect(nextRows.count == 1 && nextRows[0].label.contains("10:00"), "next row carries the start time")
        let laterRows = sections.first { $0.header == "LATER TODAY" }?.rows ?? []
        check.expect(laterRows.first?.label.contains("Focus block") == true, "muted event stays visible in later rows")
        check.expect(laterRows.first?.isEnabled == false, "muted row is disabled")

        let tree = AgendaMenu.nodes(sections: sections)
        check.expect(tree.children.first?.isEnabled == false, "section headers are disabled rows")
        let joinRow = tree.children.first { !$0.action.isEmpty && $0.action.hasPrefix("join:") }
        check.expect(joinRow?.action == "join:https://meet.example.com/daily", "menu tree preserves join actions")
        let flat = tree.children.map(\.label).joined(separator: "|")
        check.expect(flat.contains("TOMORROW") && flat.contains("Planning"), "menu tree carries tomorrow rows")

        let empty = AgendaMenu.sections(events: [], now: now)
        check.expect(empty.first?.rows.first?.label == "No upcoming meetings", "empty agenda placeholder row")
    }

    // MARK: Fixtures

    static func calendar(_ body: String) -> String {
        "BEGIN:VCALENDAR\nVERSION:2.0\n" + body + "\nEND:VCALENDAR\n"
    }

    static func event(_ uid: String, _ properties: String) -> String {
        "BEGIN:VEVENT\nUID:\(uid)\n" + properties + "\nEND:VEVENT"
    }

    static func icsStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    static func writeFeed(_ text: String, to root: URL) throws -> URL {
        let url = root.appendingPathComponent("feed.ics")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.data(using: .utf8)?.write(to: url)
        return url
    }

    /// The full v1 loop against fixtures: file feed fetch through core paths,
    /// tray agenda publication, bar title, join click, toast delivery.
    static func storeLoop(_ check: inout Check) async throws {
        let app = try DBusConnection.session()
        app.startPump()
        defer { app.shutdown() }
        let desktop = try DBusConnection.session()
        desktop.startPump()
        defer { desktop.shutdown() }
        _ = try StatusNotifierFixtures.Watcher(connection: desktop)
        let daemon = try StatusNotifierFixtures.Notifications(connection: desktop)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-linux-selftest-store-" + UUID().uuidString)
        let now = Date()
        let start = now.addingTimeInterval(120)
        let properties = "DTSTART:" + icsStamp(start)
            + "\nDTEND:" + icsStamp(start.addingTimeInterval(1_800))
            + "\nSUMMARY:Retro"
            + "\nDESCRIPTION:Join at https://meet.example.com/j/retro"
        let feed = calendar(event("store-1", properties))
        let feedURL = try writeFeed(feed, to: root)
        var prefs = Persisted()
        prefs.settings.reminderLeadSeconds = [300]
        prefs.subscriptions = [CalendarSubscription(
            name: "Test", url: feedURL.absoluteString, colorIndex: 0, colorHex: ""
        )]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(prefs).write(to: root.appendingPathComponent("preferences.json"))

        let joins = ActionRecorder()
        let autostart = root.appendingPathComponent("autostart")
        var launchPrefs = prefs
        launchPrefs.settings.launchAtLogin = true
        try JSONEncoder().encode(launchPrefs).write(to: root.appendingPathComponent("preferences.json"))
        let store = LinuxStore(
            root: root, connection: app,
            logging: { _ in }, openJoin: { joins.record($0.absoluteString) },
            autostartDirectory: autostart
        )
        try await store.startup()

        @Sendable func currentLayout() -> DBusMenu.LayoutView? {
            let reply = try? desktop.call(
                destination: app.uniqueName, path: "/MenuBar",
                interface: DBusMenu.interface, member: "GetLayout",
                arguments: [.int32(0), .int32(-1), .stringArray([])]
            )
            return reply.flatMap { DBusMenu.LayoutView.parse($0) }
        }

        final class ViewBox: @unchecked Sendable {
            var view: DBusMenu.LayoutView?
        }
        let box = ViewBox()
        let appeared = await poll {
            box.view = currentLayout()
            return box.view?.childRows.contains { $0.label.contains("Retro") } == true
        }
        check.expect(appeared, "fetched agenda row appears in the tray menu")
        check.expect(box.view?.childRows.contains { $0.label.contains("REMINDERS") } == true,
                     "menu carries the reminders footer")

        let titleReply = try desktop.call(
            destination: await store.trayServiceName, path: "/StatusNotifierItem",
            interface: "org.freedesktop.DBus.Properties", member: "GetAll",
            arguments: [.string(StatusNotifier.itemInterface)]
        )
        let title = titleReply.readPropertyDict()?["Title"] ?? ""
        check.expect(title == "2m" || title.contains("m"), "bar title counts down (got: \(title))")

        // The event is 2 minutes out with a 300 s lead: due immediately.
        await store.tick()
        let toasted = await poll { daemon.notifiedSummaries.contains("Retro") }
        check.expect(toasted, "due reminder delivered as a toast with the event title")

        // Snooze the delivered reminder, then verify a further tick stays quiet.
        let snoozeRow = currentLayout()?.childRows.first { $0.label.hasPrefix("Snooze 10 min") }
        check.expect(snoozeRow != nil, "delivered reminder exposes snooze rows")
        if let snoozeRow {
            _ = try desktop.call(
                destination: app.uniqueName, path: "/MenuBar",
                interface: DBusMenu.interface, member: "Event",
                arguments: [.int32(snoozeRow.identifier), .string("clicked"), .variant(.string("")), .int64(0)]
            )
            let snoozed = await poll { !currentLayout()!.childRows.contains { $0.label.hasPrefix("Snooze 10 min") } }
            check.expect(snoozed, "snooze click clears the snooze rows")
            await store.tick()
            try? await Task.sleep(nanoseconds: 300_000_000)
            check.expect(daemon.notifiedSummaries.filter { $0 == "Retro" }.count == 1,
                         "snoozed reminder does not re-deliver on the next tick")
        }

        if let row = box.view?.childRows.first(where: { $0.label.contains("Retro") }) {
            _ = try desktop.call(
                destination: app.uniqueName, path: "/MenuBar",
                interface: DBusMenu.interface, member: "Event",
                arguments: [.int32(row.identifier), .string("clicked"), .variant(.string("")), .int64(0)]
            )
            let joined = await poll { joins.actions.contains("https://meet.example.com/j/retro") }
            check.expect(joined, "tray join click opens the meeting link")
        } else {
            check.expect(false, "agenda row exposes a clickable id")
        }
        let entry = autostart.appendingPathComponent("now-linux.desktop")
        let entryText = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
        check.expect(entryText.contains("Type=Application") && entryText.contains("Exec=now-linux run"),
                     "launch-at-login writes an XDG autostart entry (next-login semantics)")
        try? FileManager.default.removeItem(at: root)
    }
}
