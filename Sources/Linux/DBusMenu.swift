import CDBus
import Foundation

/// The `com.canonical.dbusmenu` surface the tray item's Menu property points
/// at, following the proven Omarchy/Hyprland probe configuration. Menus are
/// small value trees; publishing a new tree bumps the revision and emits
/// LayoutUpdated, and Event delivers semantic actions ("join", "snooze",
/// "pause", "quit") to the owner.
enum DBusMenu {
    static let interface = "com.canonical.dbusmenu"

    /// A menu node; `action` is the semantic id delivered on click, empty for
    /// sections and separators.
    struct Node: Sendable {
        var id: Int32
        var label = ""
        var isSeparator = false
        var isEnabled = true
        var action = ""
        var children: [Node] = []

        static func item(_ id: Int32, _ label: String, action: String = "", enabled: Bool = true) -> Node {
            var node = Node(id: id)
            node.label = label
            node.action = action
            node.isEnabled = enabled
            return node
        }

        static func separator(_ id: Int32) -> Node {
            var node = Node(id: id)
            node.isSeparator = true
            return node
        }
    }

    /// Owns the current tree and exports it at a fixed object path.
    final class Publisher: @unchecked Sendable {
        private let lock = NSLock()
        private let connection: DBusConnection
        private let path: String
        private var root = Node(id: 0)
        private var revision: UInt32 = 0
        private var actions: [Int32: String] = [:]
        private var nodesByID: [Int32: Node] = [:]
        private var actionHandler: (@Sendable (String) -> Void)?

        init(connection: DBusConnection, path: String) {
            self.connection = connection
            self.path = path
            reindex()
            export()
        }

        /// Installs the click sink; runs on the connection's pump thread.
        func onAction(_ handler: @escaping @Sendable (String) -> Void) {
            lock.lock()
            actionHandler = handler
            lock.unlock()
        }

        /// Publishes a new tree and announces it with LayoutUpdated.
        func update(_ root: Node) {
            lock.lock()
            self.root = root
            revision += 1
            let current = revision
            reindexLocked()
            lock.unlock()
            try? connection.emitSignal(
                path: path, interface: DBusMenu.interface, member: "LayoutUpdated",
                arguments: [.uint32(current), .int32(0)]
            )
        }

        var currentRevision: UInt32 {
            lock.lock(); defer { lock.unlock() }
            return revision
        }

        // MARK: Export

        private func reindex() {
            reindexLocked()
        }

        private func reindexLocked() {
            var flat: [Int32: Node] = [:]
            flatten(root, into: &flat)
            nodesByID = flat
            var index: [Int32: String] = [:]
            func walk(_ node: Node) {
                if !node.action.isEmpty { index[node.id] = node.action }
                for child in node.children { walk(child) }
            }
            walk(root)
            actions = index
        }

        private func flatten(_ node: Node, into map: inout [Int32: Node]) {
            map[node.id] = node
            for child in node.children { flatten(child, into: &map) }
        }

        private func export() {
            let publisher = self
            connection.addObject(path: path) { member, interface, _, arguments in
                guard interface == DBusMenu.interface ||
                    (interface == "org.freedesktop.DBus.Properties" && member == "GetAll") else { return nil }
                switch member {
                case "GetAll":
                    return [.dictEntries([
                        ("Version", .uint32(3)),
                        ("TextDirection", .string("ltr")),
                        ("Status", .string("normal")),
                    ])]
                case "GetLayout":
                    return publisher.layoutReply(arguments)
                case "GetGroupProperties":
                    return publisher.groupProperties(arguments)
                case "Event":
                    publisher.handleEvent(arguments)
                    return []
                default:
                    // GetGroupProperties/GetProperty/EventGroup stay minimal:
                    // empty answers a menu host can live with.
                    return [.array(signature: "(ia{sv})", values: [])]
                }
            }
        }

        private func layoutReply(_ arguments: DBusMessageReader) -> [DBusValue] {
            let reader = arguments
            _ = reader.readInt32()  // parentId: the whole tree is published
            _ = reader.readInt32()  // recursionDepth: ignored, full depth
            _ = reader.readStringArray()  // propertyNames: all properties
            lock.lock()
            let tree = root
            let current = revision
            lock.unlock()
            return [.uint32(current), .structure(layout(of: tree))]
        }

        func groupProperties(_ arguments: DBusMessageReader) -> [DBusValue] {
            let ids = arguments.readInt32Array() ?? []
            var entries: [DBusValue] = []
            for id in ids {
                guard let node = node(id) else { continue }
                entries.append(.structure([.int32(id), .dictEntries(propertyList(of: node))]))
            }
            return [.array(signature: "(ia{sv})", values: entries)]
        }

        private func node(_ id: Int32) -> Node? {
            lock.lock(); defer { lock.unlock() }
            return nodesByID[id]
        }

        func propertyList(of node: Node) -> [(String, DBusValue)] {
            var properties: [(String, DBusValue)] = []
            if node.isSeparator {
                properties.append(("type", .string("separator")))
            } else {
                properties.append(("type", .string("standard")))
                properties.append(("label", .string(node.label)))
                properties.append(("enabled", .boolean(node.isEnabled)))
            }
            if !node.children.isEmpty {
                properties.append(("children-display", .string("submenu")))
            }
            return properties
        }

        private func layout(of node: Node) -> [DBusValue] {
            let properties = propertyList(of: node)
            let children = node.children.map { DBusValue.variant(.structure(layout(of: $0))) }
            return [
                .int32(node.id),
                .dictEntries(properties),
                .array(signature: "v", values: children),
            ]
        }

        private func handleEvent(_ arguments: DBusMessageReader) {
            let reader = arguments
            guard let id = reader.readInt32(),
                  let eventId = reader.readString(), eventId == "clicked" else { return }
            lock.lock()
            let action = actions[id]
            let handler = actionHandler
            lock.unlock()
            guard let action, let handler else { return }
            handler(action)
        }
    }

    /// Minimal client-side layout walk for tests and the future panel probe:
    /// (u revision, (i id, a{sv} properties, av children)).
    struct LayoutView: Sendable {
        var revision: UInt32
        var identifier: Int32
        var properties: [String: String]
        var childRows: [(identifier: Int32, label: String)]

        static func parse(_ reader: DBusMessageReader) -> LayoutView? {
            guard let revision = reader.readUint32(),
                  let layoutStructure = reader.recurseInto(),
                  let identifier = layoutStructure.readInt32(),
                  let properties = layoutStructure.readPropertyDict(),
                  let children = layoutStructure.recurseInto() else { return nil }
            var rows: [(Int32, String)] = []
            while children.currentType == CDBusTypeVariant {
                if let variant = children.recurseInto(),
                   let node = variant.recurseInto(),
                   let nodeIdentifier = node.readInt32(),
                   let nodeProperties = node.readPropertyDict() {
                    rows.append((nodeIdentifier, nodeProperties["label"] ?? "separator:\\(nodeIdentifier)"))
                }
                children.step()
            }
            return LayoutView(revision: revision, identifier: identifier, properties: properties, childRows: rows)
        }
    }
}
