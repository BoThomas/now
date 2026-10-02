import Foundation

/// The Linux tray surface: one StatusNotifierItem registered with
/// org.kde.StatusNotifierWatcher, mirroring the proven Omarchy/Hyprland probe
/// configuration (`ItemIsMenu=true`, menu-only clicks, one-shot idempotent
/// re-registration when the watcher's bus name changes owner).
enum StatusNotifier {
    static let watcherService = "org.kde.StatusNotifierWatcher"
    static let watcherPath = "/StatusNotifierWatcher"
    static let watcherInterface = "org.kde.StatusNotifierWatcher"
    static let itemInterface = "org.kde.StatusNotifierItem"
    static let notificationsService = "org.freedesktop.Notifications"
    static let notificationsPath = "/org/freedesktop/Notifications"
    static let notificationsInterface = "org.freedesktop.Notifications"

    /// The tray item the shell exports; `menuPath` is where the dbusmenu
    /// surface will live (exported from M2 on).
    struct ItemConfiguration: Sendable {
        var identifier = "now"
        var title = "now"
        var category = "SystemServices"
        var iconName = "now"
        var menuPath = "/MenuBar"
        /// Directory holding <iconName>.png for name-based hosts.
        var iconThemePath = ""
    }

    /// Owns the item bus name and keeps registration current. All D-Bus work
    /// stays on the calling task; state is lock-guarded because handlers run
    /// on the connection's pump thread.
    final class Registrar: @unchecked Sendable {
        private let lock = NSLock()
        private let connection: DBusConnection
        private let configuration: ItemConfiguration
        private let logging: @Sendable (String) -> Void
        let serviceName: String
        private static let instances = InstanceCounter()
        private var registeredWithCurrentOwner = false
        private(set) var registrationCount = 0

        /// Lock-guarded instance ids so several registrars (app plus tests)
        /// never collide on one StatusNotifierItem bus name.
        private final class InstanceCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func next() -> Int {
                lock.lock(); defer { lock.unlock() }
                count += 1
                return count
            }
        }

        init(connection: DBusConnection, configuration: ItemConfiguration = ItemConfiguration(),
             logging: @escaping @Sendable (String) -> Void = { _ in }) {
            self.connection = connection
            self.configuration = configuration
            self.logging = logging
            // The first instance keeps the conventional `-pid-1` name a real
            // single-instance app uses; later instances (tests) get unique ids.
            serviceName = "\(StatusNotifier.itemInterface)-\(ProcessInfo.processInfo.processIdentifier)-\(Self.instances.next())"
        }

        /// Answers the org.freedesktop.DBus.Properties surface; ItemIsMenu=true
        /// keeps the item menu-only per the recorded probe behavior. Title is
        /// boxed so the bar countdown can update in place and announce
        /// NewTitle.
        func registerObject() throws {
            let properties = PropertyBox()
            properties.set([
                "Category": .string(configuration.category),
                "Id": .string(configuration.identifier),
                "Title": .string(configuration.title),
                "IconName": .string(configuration.iconName),
                "IconThemePath": .string(configuration.iconThemePath),
                "IconPixmap": .array(signature: "(iiay)", values: [{ () -> DBusValue in
                    let (width, height, bytes) = LinuxIcon.pixmap(size: 24)
                    return .structure([.int32(Int32(width)), .int32(Int32(height)), .byteArray(bytes)])
                }()]),
                "ItemIsMenu": .boolean(true),
                "Menu": .string(configuration.menuPath),
            ])
            self.properties = properties
            let surface = StatusNotifier.itemInterface
            connection.addObject(path: "/StatusNotifierItem") { member, interface, _, arguments in
                guard interface == "org.freedesktop.DBus.Properties" || interface == surface else { return nil }
                if member == "GetAll" {
                    return [.dictEntries(properties.current().map { ($0.key, $0.value) })]
                }
                if member == "Get" {
                    let reader2 = arguments
                    let requested = reader2.readString() ?? reader2.readString()
                    if let requested, let value = properties.current()[requested] {
                        return [.variant(value)]
                    }
                    return nil
                }
                // Activate/SecondaryActivate/Scroll stay menu-only no-ops.
                return []
            }
            let outcome = try connection.requestName(serviceName)
            guard outcome == .primaryOwner || outcome == .alreadyOwner else {
                throw DBusFailure("cannot own \(serviceName)")
            }
            try? connection.emitSignal(
                path: "/StatusNotifierItem", interface: StatusNotifier.itemInterface, member: "NewIcon", arguments: []
            )
        }

        /// Publishes a new bar title and announces it with NewTitle.
        func updateTitle(_ title: String) {
            guard let properties else { return }
            var next = properties.current()
            next["Title"] = .string(title)
            properties.set(next)
            try? connection.emitSignal(
                path: "/StatusNotifierItem", interface: StatusNotifier.itemInterface, member: "NewTitle",
                arguments: [.string(title)]
            )
        }

        /// Lock-guarded property table read by the pump thread's handler.
        private final class PropertyBox: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String: DBusValue] = [:]
            func set(_ values: [String: DBusValue]) {
                lock.lock(); self.values = values; lock.unlock()
            }
            func current() -> [String: DBusValue] {
                lock.lock(); defer { lock.unlock() }
                return values
            }
        }

        private var properties: PropertyBox?

        /// Subscribes to watcher ownership changes and registers once now;
        /// re-registration is one-shot per new owner (the watcher dedupes
        /// duplicates, the probe showed a single retry suffices).
        func connect(watchForRestart: Bool = true, initialTimeout seconds: TimeInterval) async throws {
            if watchForRestart {
                connection.addSignalHandler(interface: "org.freedesktop.DBus", member: "NameOwnerChanged") { [weak self] reader in
                    guard let self else { return }
                    let arguments = reader
                    guard let name = arguments.readString(), name == StatusNotifier.watcherService,
                          let oldOwner = arguments.readString(), let newOwner = arguments.readString() else { return }
                    if oldOwner.isEmpty, !newOwner.isEmpty {
                        self.invalidateRegistration()
                        Task { try? await self.registerOnce(timeoutMs: 3_000) }
                    }
                }
            }
            // The panel may start after the app (autostart order); retry
            // instead of dying, and let NameOwnerChanged finish the job if
            // the watcher appears even later.
            for attempt in 1...15 {
                do {
                    try await registerOnce(timeoutMs: 1_000)
                    return
                } catch {
                    if attempt == 15 { logging("watcher not available yet; waiting for it to appear") }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        func registerOnce(timeoutMs: Int32) async throws {
            guard beginRegistration() else { return }
            _ = try connection.call(
                destination: watcherService, path: watcherPath, interface: watcherInterface,
                member: "RegisterStatusNotifierItem", arguments: [.string(serviceName)], timeoutMs: timeoutMs
            )
            let service = serviceName
            completeRegistration()
            logging("registered \(service) with \(watcherService)")
        }

        // Synchronous lock scopes; called from async code and the pump thread.

        private func beginRegistration() -> Bool {
            lock.lock()
            if registeredWithCurrentOwner {
                lock.unlock()
                return false
            }
            lock.unlock()
            return true
        }

        private func completeRegistration() {
            lock.lock()
            registeredWithCurrentOwner = true
            registrationCount += 1
            lock.unlock()
        }

        private func invalidateRegistration() {
            lock.lock()
            registeredWithCurrentOwner = false
            lock.unlock()
        }

        var registrations: Int {
            lock.lock(); defer { lock.unlock() }
            return registrationCount
        }
    }

    /// Capabilities the reminder transport can rely on; the recorded probe
    /// decision is a default-action-only toast regardless of `actions`.
    struct NotificationCapabilities: Sendable, Equatable {
        var actions = false
        var body = false

        init(capabilities: [String]) {
            actions = capabilities.contains("actions")
            body = capabilities.contains("body")
        }
    }

    static func probeNotifications(connection: DBusConnection) throws -> NotificationCapabilities {
        let reader = try connection.call(
            destination: notificationsService, path: notificationsPath, interface: notificationsInterface,
            member: "GetCapabilities"
        )
        let arguments = reader
        return NotificationCapabilities(capabilities: arguments.readStringArray() ?? [])
    }
}

/// Selftest fixtures: a synthetic watcher and notification daemon on the same
/// private session bus, recording what the registrar does.
enum StatusNotifierFixtures {
    final class Watcher: @unchecked Sendable {
        private let lock = NSLock()
        private let connection: DBusConnection
        private var items: [String] = []
        private(set) var registrationCount = 0

        init(connection: DBusConnection) throws {
            self.connection = connection
            let watcher = self
            connection.addObject(path: StatusNotifier.watcherPath) { member, _, _, arguments in
                guard member == "RegisterStatusNotifierItem" else { return nil }
                let reader = arguments
                guard let service = reader.readString() else { return nil }
                watcher.record(service)
                return []
            }
            let outcome = try connection.requestName(StatusNotifier.watcherService)
            guard outcome == .primaryOwner || outcome == .alreadyOwner else {
                throw DBusFailure("fixture cannot own \(StatusNotifier.watcherService)")
            }
        }

        private func record(_ service: String) {
            lock.lock()
            registrationCount += 1
            if !items.contains(service) { items.append(service) }
            lock.unlock()
        }

        func dropAndReown() throws {
            connection.releaseName(StatusNotifier.watcherService)
            let outcome = try connection.requestName(StatusNotifier.watcherService)
            guard outcome == .primaryOwner else {
                throw DBusFailure("fixture cannot re-own watcher name")
            }
        }

        var registeredItems: [String] {
            lock.lock(); defer { lock.unlock() }
            return items
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return registrationCount
        }
    }

    final class Notifications: @unchecked Sendable {
        private let lock = NSLock()
        private var capabilityQueries = 0
        private var notified: [String] = []

        init(connection: DBusConnection, capabilities: [String] = ["actions", "body"]) throws {
            let daemon = self
            connection.addObject(path: StatusNotifier.notificationsPath) { member, _, _, arguments in
                switch member {
                case "GetCapabilities":
                    daemon.noteQuery()
                    return [.stringArray(capabilities)]
                case "Notify":
                    daemon.noteNotify(summary: daemon.summary(from: arguments))
                    return [.uint32(1)]
                default:
                    return []
                }
            }
            let outcome = try connection.requestName(StatusNotifier.notificationsService)
            guard outcome == .primaryOwner || outcome == .alreadyOwner else {
                throw DBusFailure("fixture cannot own \(StatusNotifier.notificationsService)")
            }
        }

        private func noteQuery() {
            lock.lock(); capabilityQueries += 1; lock.unlock()
        }

        private func noteNotify(summary: String?) {
            lock.lock(); capabilityQueries += 1; notified.append(summary ?? "?"); lock.unlock()
        }

        private func summary(from reader: DBusMessageReader) -> String? {
            let arguments = reader
            _ = arguments.readString()  // app_name
            _ = arguments.readUint32()  // replaces_id
            _ = arguments.readString()  // app_icon
            return arguments.readString()  // summary
        }

        func queries() -> Int {
            lock.lock(); defer { lock.unlock() }
            return capabilityQueries
        }

        var notifiedSummaries: [String] {
            lock.lock(); defer { lock.unlock() }
            return notified
        }
    }
}
