import Foundation
import Combine
import OSLog

/// Production persistence uses the standard domain. The signed updater fixture must
/// keep its pinned bundle ID, so its compilation uses an explicit disposable suite.
enum AppPreferences {
    static var standard: UserDefaults {
        #if NOW_UPDATER_TESTS
        guard let domain = ProcessInfo.processInfo.environment["NOW_TEST_PREFERENCES_DOMAIN"],
              domain.hasPrefix("com.thomasboch.now.updater-smoke."),
              let defaults = UserDefaults(suiteName: domain) else {
            preconditionFailure("Updater fixture requires disposable preferences")
        }
        return defaults
        #else
        return UserDefaults.standard
        #endif
    }
}

/// Attached to one decoder. Tolerant model decoding records damaged fields
/// without turning a recoverable sibling into a failed profile.
final class PreferenceDecoding: @unchecked Sendable {
    static let key = CodingUserInfoKey(rawValue: "now.preference-recovery")!
    private let lock = NSLock()
    private var didRecover = false
    var recovered: Bool { lock.lock(); defer { lock.unlock() }; return didRecover }
    static func note(_ decoder: Decoder) {
        guard let audit = decoder.userInfo[key] as? PreferenceDecoding else { return }
        audit.lock.lock(); audit.didRecover = true; audit.lock.unlock()
    }
}

extension KeyedDecodingContainer {
    func recover<T: Decodable>(_ type: T.Type, forKey key: Key, decoder: Decoder, allowNull: Bool = false) -> T? {
        guard contains(key) else { return nil } // missing fields can be migrations
        do {
            if try decodeNil(forKey: key) {
                if !allowNull { PreferenceDecoding.note(decoder) }
                return nil
            }
            return try decode(type, forKey: key)
        } catch { PreferenceDecoding.note(decoder); return nil }
    }
}

@MainActor
final class PersistenceStatus: ObservableObject {
    static let shared = PersistenceStatus()
    @Published private(set) var issues: [String: String] = [:]
    private static let logger = Logger(subsystem: "com.thomasboch.now", category: "persistence")

    func report(key: String, message: String, defaults: UserDefaults) {
        // Log only fixed labels/messages, never calendar URLs or raw decoding errors.
        Self.logger.error("\(message, privacy: .public)")
        if defaults === AppPreferences.standard { issues[key] = message }
    }

    func reviewed(_ key: String) {
        AppPreferences.standard.set(true, forKey: StoredPreferences.reviewedKey(key))
        issues.removeValue(forKey: key)
    }
}

/// Preference recovery is separate from the live payload. The original damaged
/// value survives launch migrations; a verified last-good copy can restore
/// reminder history. UserDefaults writes don't provide a disk-error result, so
/// this reports encoding/recovery failures without claiming durable disk flushes.
@MainActor
enum StoredPreferences {
    static func backupKey(_ key: String) -> String { key + ".last-good.v1" }
    static func recoveryKey(_ key: String) -> String { key + ".recovery.v1" }
    static func reviewedKey(_ key: String) -> String { key + ".recovery-reviewed.v1" }

    static func needsReview(_ key: String, defaults: UserDefaults = AppPreferences.standard) -> Bool {
        defaults.object(forKey: recoveryKey(key)) != nil && !defaults.bool(forKey: reviewedKey(key))
    }

    private static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> (T, Bool) {
        let audit = PreferenceDecoding()
        let decoder = JSONDecoder()
        decoder.userInfo[PreferenceDecoding.key] = audit
        let value = try decoder.decode(type, from: data)
        return (value, audit.recovered)
    }

    static func load<T: Decodable>(_ type: T.Type, key: String, label: String,
                                  defaults: UserDefaults = AppPreferences.standard, maxBytes: Int = 16_000_000) -> T? {
        let notice = "\(label) needed recovery. Saved copies were kept; please review your settings and calendars."
        if needsReview(key, defaults: defaults) {
            PersistenceStatus.shared.report(key: key, message: notice, defaults: defaults)
        }
        guard let original = defaults.object(forKey: key) else { return nil }
        var partial: T?
        if let data = original as? Data, data.count <= maxBytes,
           let (value, recovered) = try? decode(type, data: data) {
            if !recovered { return value }
            partial = value
        }
        // Keep the first original plus the two latest failures, bounded per key.
        var copies = defaults.array(forKey: recoveryKey(key)) ?? []
        if !copies.contains(where: { NSDictionary(dictionary: ["value": $0]).isEqual(to: ["value": original]) }) {
            if copies.count >= 3 { copies.remove(at: 1) }
            copies.append(original)
            defaults.set(copies, forKey: recoveryKey(key))
        }
        defaults.set(false, forKey: reviewedKey(key))
        PersistenceStatus.shared.report(key: key, message: notice, defaults: defaults)
        if let backup = defaults.data(forKey: backupKey(key)), backup.count <= maxBytes,
           let (value, recovered) = try? decode(type, data: backup), !recovered {
            return value
        }
        return partial
    }

    @discardableResult
    static func save<T: Encodable>(_ value: T, key: String, label: String,
                                   defaults: UserDefaults = AppPreferences.standard, maxBytes: Int = 16_000_000) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            guard data.count <= maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            if defaults.data(forKey: backupKey(key)) != data { defaults.set(data, forKey: backupKey(key)) }
            if defaults.data(forKey: key) != data { defaults.set(data, forKey: key) }
            return true
        } catch {
            PersistenceStatus.shared.report(key: key, message: "\(label) could not be saved. Your previous saved copy was kept.", defaults: defaults)
            return false
        }
    }
}
