import Foundation

/// A decoder-local presentation policy. An unconfigured decoder retains the existing
/// empty-color sentinel; a platform importing legacy profiles supplies its own palette.
package enum ModelDecoding {
    private static let calendarColorKey = CodingUserInfoKey(rawValue: "now.calendar-color-default")!

    package static func decoder(calendarColor: @escaping @Sendable (Int) -> String) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[calendarColorKey] = calendarColor
        return decoder
    }

    static func defaultCalendarColor(at index: Int, decoder: Decoder) -> String {
        let color = decoder.userInfo[calendarColorKey] as? (@Sendable (Int) -> String)
        return color?(index) ?? ""
    }
}

/// Attached to one decoder. Tolerant model decoding records damaged fields
/// without turning a recoverable sibling into a failed profile.
package final class PreferenceDecoding: @unchecked Sendable {
    package init() {}
    package static let key = CodingUserInfoKey(rawValue: "now.preference-recovery")!
    private let lock = NSLock()
    private var didRecover = false
    package var recovered: Bool { lock.lock(); defer { lock.unlock() }; return didRecover }
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
