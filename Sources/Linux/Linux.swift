import Foundation

#if os(Linux)
import Glibc
#endif

@main enum LinuxMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let mode = arguments.first else {
            print("usage: now-linux selftest")
            return
        }
        switch mode {
        case "selftest": await SelfTest.run()
        default: print("unknown mode: \(mode)"); exit(2)
        }
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
        } catch {
            check.expect(false, "scenario failed: \(error)")
        }
        if !check.failures.isEmpty {
            for failure in check.failures { print("FAIL: \(failure)") }
            exit(1)
        }
        print("LINUX SHELL OK — \(check.count) checks; bus connect, name ownership, watcher registration, property export, restart re-registration, notification capabilities, dbusmenu export/events/revisions")
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
        check.expect(view.childLabels.count == 3, "agenda menu rows exported")
        check.expect(view.childLabels.first == "Join standup", "agenda labels carry meeting titles")

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
        check.expect(second.childLabels.count == 4, "updated menu carries the snooze row")
        check.expect(updates.actions.contains("2"), "LayoutUpdated announced the new revision")
    }
}
