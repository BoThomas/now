import CDBus
import Foundation

#if os(Linux)
import Glibc
#endif

/// A D-Bus value for the Linux shell's narrow wire surface: scalars, string
/// arrays, and `a{sv}` property maps.
indirect enum DBusValue: Sendable {
    case string(String)
    case boolean(Bool)
    case int32(Int32)
    case uint32(UInt32)
    case stringArray([String])
    case variant(DBusValue)
    case dictEntries([(String, DBusValue)])
}

/// Transport failures of the libdbus layer; the shell reports them, never
/// crashes on them (named `Failure` because libdbus owns `DBusError`).
struct DBusFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

private func cString(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? ""
}

/// One private session-bus connection. libdbus is initialized for threads and
/// does its own internal serialization; a dedicated pump thread runs
/// `read_write_dispatch` so incoming method calls reach handlers while other
/// tasks issue blocking calls. Handlers run on the pump thread and must not
/// call back into the connection synchronously.
final class DBusConnection: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: OpaquePointer
    private var pumpThread: Thread?
    private var stopped = false
    private var closed = false
    private var pumpRunning = false
    private var objectHandlers: [String: (String, String, String, DBusMessageReader) -> [DBusValue]?] = [:]
    private var signalHandlers: [@Sendable (DBusMessageReader) -> Void] = []
    private var filterInstalled = false

    static func session() throws -> DBusConnection {
        _ = dbus_threads_init_default()
        var error = DBusError()
        dbus_error_init(&error)
        let connection = dbus_bus_get_private(DBusBusType(UInt32(CDBusBusTypeSession)), &error)
        guard let connection, dbus_connection_get_is_connected(connection) != 0 else {
            throw DBusFailure("session bus unavailable: \(cString(error.message))")
        }
        dbus_connection_set_exit_on_disconnect(connection, 0)
        return DBusConnection(connection)
    }

    private init(_ connection: OpaquePointer) {
        self.connection = connection
    }

    deinit {
        if !closed {
            dbus_connection_close(connection)
            dbus_connection_unref(connection)
        }
    }

    /// Deterministic teardown: stops the pump, waits for it to leave libdbus,
    /// closes the connection, and releases every bus name it owned. Callers
    /// must keep the connection (and its registered objects) alive until
    /// shutdown; afterwards the instance must not be used.
    func shutdown() {
        stopPump()
        lock.lock()
        while pumpRunning {
            lock.unlock()
            usleep(1_000)
            lock.lock()
        }
        if !closed {
            closed = true
            dbus_connection_close(connection)
            dbus_connection_unref(connection)
        }
        lock.unlock()
    }

    var uniqueName: String {
        cString(dbus_bus_get_unique_name(connection))
    }

    // MARK: Name ownership

    enum NameRequest { case primaryOwner, alreadyOwner, taken, denied }

    func requestName(_ name: String, allowReplacement: Bool = false) throws -> NameRequest {
        var flags: Int32 = CDBusNameFlagDoNotQueue
        if allowReplacement { flags |= CDBusNameFlagAllowReplacement }
        var error = DBusError()
        dbus_error_init(&error)
        let reply = dbus_bus_request_name(connection, name, UInt32(flags), &error)
        guard dbus_error_is_set(&error) == 0 else {
            throw DBusFailure("requestName(\(name)): \(cString(error.message))")
        }
        switch Int(reply) {
        case Int(CDBusRequestNameReplyPrimaryOwner): return .primaryOwner
        case Int(CDBusRequestNameReplyAlreadyOwner): return .alreadyOwner
        case Int(CDBusRequestNameReplyExists): return .taken
        default: return .denied
        }
    }

    func releaseName(_ name: String) {
        var error = DBusError()
        dbus_error_init(&error)
        dbus_bus_release_name(connection, name, &error)
        dbus_error_free(&error)
    }

    // MARK: Method calls and signals

    func call(destination: String, path: String, interface: String, member: String,
              arguments: [DBusValue] = [], timeoutMs: Int32 = 5_000) throws -> DBusMessageReader {
        let message = dbus_message_new_method_call(destination, path, interface, member)
        guard let message else { throw DBusFailure("cannot allocate call to \(member)") }
        defer { dbus_message_unref(message) }
        if !arguments.isEmpty {
            try DBusMessageWriter.append(arguments, to: message)
        }
        var error = DBusError()
        dbus_error_init(&error)
        guard let reply = dbus_connection_send_with_reply_and_block(connection, message, timeoutMs, &error) else {
            throw DBusFailure("call \(interface).\(member): \(cString(error.message))")
        }
        defer { dbus_message_unref(reply) }
        return DBusMessageReader(reply)
    }

    func emitSignal(path: String, interface: String, member: String, arguments: [DBusValue]) throws {
        let message = dbus_message_new_signal(path, interface, member)
        guard let message else { throw DBusFailure("cannot allocate signal \(member)") }
        defer { dbus_message_unref(message) }
        if !arguments.isEmpty { try DBusMessageWriter.append(arguments, to: message) }
        var serial: UInt32 = 0
        guard dbus_connection_send(connection, message, &serial) != 0 else {
            throw DBusFailure("cannot send signal \(member)")
        }
        dbus_connection_flush(connection)
    }

    // MARK: Object export and signal delivery

    func addObject(path: String, handler: @Sendable @escaping (_ member: String, _ interface: String, _ sender: String, _ arguments: DBusMessageReader) -> [DBusValue]?) {
        lock.lock()
        objectHandlers[path] = handler
        lock.unlock()
        // Unretained: callers must keep this connection alive as long as the
        // path is registered (documented on shutdown()).
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        dbus_connection_register_object_path(connection, path, &objectVTable, pointer)
    }

    /// Adds a signal handler for `interface,member`; handlers see every signal
    /// whose match rule names that member. Signals reach handlers through the
    /// connection's message filter — libdbus never routes signals to
    /// registered object paths.
    func addSignalHandler(interface: String, member: String, handler: @Sendable @escaping (DBusMessageReader) -> Void) {
        let rule = "type='signal',interface='\(interface)',member='\(member)'"
        var error = DBusError()
        dbus_error_init(&error)
        dbus_bus_add_match(connection, rule, &error)
        dbus_error_free(&error)
        lock.lock()
        signalHandlers.append(handler)
        let needsFilter = !filterInstalled
        filterInstalled = true
        lock.unlock()
        if needsFilter {
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            dbus_connection_add_filter(
                connection,
                { _, message, data in
                    guard let message, let data else { return DBUS_HANDLER_RESULT_NOT_YET_HANDLED }
                    let myself = Unmanaged<DBusConnection>.fromOpaque(data).takeUnretainedValue()
                    return myself.handleSignal(message)
                },
                pointer,
                nil
            )
        }
    }

    // MARK: Pumping

    func startPump() {
        lock.lock()
        guard pumpThread == nil, !stopped, !closed else { lock.unlock(); return }
        pumpRunning = true
        let thread = Thread { [weak self] in
            while let self, !self.checkStopped() {
                if dbus_connection_get_is_connected(self.connection) == 0 { break }
                dbus_connection_read_write_dispatch(self.connection, 20)
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard let self else { return }
            self.lock.lock()
            self.pumpRunning = false
            self.lock.unlock()
        }
        pumpThread = thread
        lock.unlock()
        thread.start()
    }

    func stopPump() {
        lock.lock()
        stopped = true
        pumpThread = nil
        lock.unlock()
    }

    private func checkStopped() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    // MARK: Dispatch callbacks (libdbus trampolines)

    private var objectVTable = DBusObjectPathVTable(
        unregister_function: { _, _ in },
        message_function: { connection, message, data in
            guard let message, let data, let connection else { return DBUS_HANDLER_RESULT_NOT_YET_HANDLED }
            let myself = Unmanaged<DBusConnection>.fromOpaque(data).takeUnretainedValue()
            return myself.handleMessage(message, connection: connection)
        },
        dbus_internal_pad1: nil,
        dbus_internal_pad2: nil,
        dbus_internal_pad3: nil,
        dbus_internal_pad4: nil
    )

    private func handleMessage(_ message: OpaquePointer, connection: OpaquePointer) -> DBusHandlerResult {
        guard dbus_message_get_type(message) == CDBusMessageTypeMethodCall else {
            return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
        }
        let reader = DBusMessageReader(message)
        let path = cString(dbus_message_get_path(message))
        lock.lock()
        let handler = objectHandlers[path]
        lock.unlock()
        guard let handler else { return DBUS_HANDLER_RESULT_NOT_YET_HANDLED }
        let member = cString(dbus_message_get_member(message))
        let interface = cString(dbus_message_get_interface(message))
        let sender = cString(dbus_message_get_sender(message))
        let reply = handler(member, interface, sender, reader)
        let replyMessage = reply != nil
            ? dbus_message_new_method_return(message)
            : dbus_message_new_error(message, CDBusErrorFailed, "unhandled member \(interface).\(member)")
        guard let replyMessage else { return DBUS_HANDLER_RESULT_HANDLED }
        defer { dbus_message_unref(replyMessage) }
        if let reply { try? DBusMessageWriter.append(reply, to: replyMessage) }
        var serial: UInt32 = 0
        dbus_connection_send(connection, replyMessage, &serial)
        dbus_connection_flush(connection)
        return DBUS_HANDLER_RESULT_HANDLED
    }

    private func handleSignal(_ message: OpaquePointer) -> DBusHandlerResult {
        guard dbus_message_get_type(message) == CDBusMessageTypeSignal else {
            return DBUS_HANDLER_RESULT_NOT_YET_HANDLED
        }
        let reader = DBusMessageReader(message)
        lock.lock()
        let handlers = signalHandlers
        lock.unlock()
        for handler in handlers { handler(reader) }
        return DBUS_HANDLER_RESULT_HANDLED
    }
}

/// Writer for outgoing arguments: scalars, string arrays, variants, and
/// property-map dictionaries.
enum DBusMessageWriter {
    static func append(_ values: [DBusValue], to message: OpaquePointer) throws {
        var iterator = DBusMessageIter()
        dbus_message_iter_init_append(message, &iterator)
        for value in values {
            try append(value, into: &iterator)
        }
    }

    private static func appendString(_ string: String, into iterator: UnsafeMutablePointer<DBusMessageIter>) {
        var buffer = Array(string.utf8CString)
        buffer.withUnsafeMutableBufferPointer { pointer in
            var base = pointer.baseAddress
            dbus_message_iter_append_basic(iterator, CDBusTypeString, &base)
        }
    }

    private static func append(_ value: DBusValue, into iterator: UnsafeMutablePointer<DBusMessageIter>) throws {
        switch value {
        case .string(let string):
            appendString(string, into: iterator)
        case .boolean(let boolean):
            var value = dbus_bool_t(boolean ? 1 : 0)
            dbus_message_iter_append_basic(iterator, CDBusTypeBoolean, &value)
        case .int32(let number):
            var number = number
            dbus_message_iter_append_basic(iterator, CDBusTypeInt32, &number)
        case .uint32(let number):
            var number = number
            dbus_message_iter_append_basic(iterator, CDBusTypeUint32, &number)
        case .stringArray(let strings):
            var array = DBusMessageIter()
            dbus_message_iter_open_container(iterator, CDBusTypeArray, "s", &array)
            for string in strings { appendString(string, into: &array) }
            dbus_message_iter_close_container(iterator, &array)
        case .variant(let inner):
            var variant = DBusMessageIter()
            var signature = Array(Self.signature(of: inner).utf8CString)
            signature.withUnsafeMutableBufferPointer { buffer in
                _ = dbus_message_iter_open_container(iterator, CDBusTypeVariant, buffer.baseAddress, &variant)
            }
            try append(inner, into: &variant)
            dbus_message_iter_close_container(iterator, &variant)
        case .dictEntries(let entries):
            var array = DBusMessageIter()
            dbus_message_iter_open_container(iterator, CDBusTypeArray, "{sv}", &array)
            for (key, inner) in entries {
                var entry = DBusMessageIter()
                dbus_message_iter_open_container(&array, CDBusTypeDictEntry, nil, &entry)
                appendString(key, into: &entry)
                try append(.variant(inner), into: &entry)
                dbus_message_iter_close_container(&array, &entry)
            }
            dbus_message_iter_close_container(iterator, &array)
        }
    }

    static func signature(of value: DBusValue) -> String {
        switch value {
        case .string: return "s"
        case .boolean: return "b"
        case .int32: return "i"
        case .uint32: return "u"
        case .stringArray: return "as"
        case .variant(let inner): return signature(of: inner)
        case .dictEntries: return "a{sv}"
        }
    }
}

/// Reader for incoming arguments and replies; single pass, position-based.
struct DBusMessageReader {
    private let message: OpaquePointer
    private var iterator = DBusMessageIter()
    private var exhausted = false

    init(_ message: OpaquePointer) {
        self.message = message
        exhausted = dbus_message_iter_init(message, &iterator) == 0
    }

    var member: String { cString(dbus_message_get_member(message)) }

    mutating func readString() -> String? {
        guard !exhausted, dbus_message_iter_get_arg_type(&iterator) == CDBusTypeString else { return nil }
        var base: UnsafeMutableRawPointer?
        dbus_message_iter_get_basic(&iterator, &base)
        advance()
        guard let base else { return nil }
        return String(cString: base.assumingMemoryBound(to: CChar.self))
    }

    mutating func readBoolean() -> Bool? {
        guard !exhausted, dbus_message_iter_get_arg_type(&iterator) == CDBusTypeBoolean else { return nil }
        var value = dbus_bool_t(0)
        dbus_message_iter_get_basic(&iterator, &value)
        advance()
        return value != 0
    }

    mutating func readInt32() -> Int32? {
        guard !exhausted, dbus_message_iter_get_arg_type(&iterator) == CDBusTypeInt32 else { return nil }
        var value: Int32 = 0
        dbus_message_iter_get_basic(&iterator, &value)
        advance()
        return value
    }

    mutating func readStringArray() -> [String]? {
        guard !exhausted, dbus_message_iter_get_arg_type(&iterator) == CDBusTypeArray else { return nil }
        var array = DBusMessageIter()
        dbus_message_iter_recurse(&iterator, &array)
        var strings: [String] = []
        while dbus_message_iter_get_arg_type(&array) == CDBusTypeString {
            var base: UnsafeMutableRawPointer?
            dbus_message_iter_get_basic(&array, &base)
            if let base { strings.append(String(cString: base.assumingMemoryBound(to: CChar.self))) }
            dbus_message_iter_next(&array)
        }
        advance()
        return strings
    }

    /// Reads `a{sv}` into labeled scalar strings; variant values keep the
    /// subset the tray surface needs (string/bool/int).
    mutating func readPropertyDict() -> [String: String]? {
        guard !exhausted, dbus_message_iter_get_arg_type(&iterator) == CDBusTypeArray else { return nil }
        var array = DBusMessageIter()
        dbus_message_iter_recurse(&iterator, &array)
        var properties: [String: String] = [:]
        while dbus_message_iter_get_arg_type(&array) == CDBusTypeDictEntry {
            var entry = DBusMessageIter()
            dbus_message_iter_recurse(&array, &entry)
            var keyBase: UnsafeMutableRawPointer?
            dbus_message_iter_get_basic(&entry, &keyBase)
            dbus_message_iter_next(&entry)
            guard let keyBase else { break }
            let key = String(cString: keyBase.assumingMemoryBound(to: CChar.self))
            if dbus_message_iter_get_arg_type(&entry) == CDBusTypeVariant {
                var variant = DBusMessageIter()
                dbus_message_iter_recurse(&entry, &variant)
                properties[key] = describe(&variant)
            }
            dbus_message_iter_next(&array)
        }
        advance()
        return properties
    }

    private func describe(_ iterator: UnsafeMutablePointer<DBusMessageIter>) -> String {
        switch dbus_message_iter_get_arg_type(iterator) {
        case CDBusTypeString:
            var base: UnsafeMutableRawPointer?
            dbus_message_iter_get_basic(iterator, &base)
            return base.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
        case CDBusTypeBoolean:
            var value = dbus_bool_t(0)
            dbus_message_iter_get_basic(iterator, &value)
            return value != 0 ? "true" : "false"
        case CDBusTypeInt32:
            var value: Int32 = 0
            dbus_message_iter_get_basic(iterator, &value)
            return String(value)
        case CDBusTypeUint32:
            var value: UInt32 = 0
            dbus_message_iter_get_basic(iterator, &value)
            return String(value)
        default:
            return "?"
        }
    }

    private mutating func advance() {
        exhausted = dbus_message_iter_next(&iterator) == 0
    }
}
