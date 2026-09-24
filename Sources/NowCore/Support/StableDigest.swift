import Foundation
#if os(macOS)
import CryptoKit
#else
import Crypto
#endif

/// Persisted identities use SHA-256 over the exact UTF-8 bytes, never Swift Hasher.
/// Apple retains CryptoKit; other supported hosts use the pinned Swift Crypto API.
package enum StableDigest {
    /// Lowercase hex digits; persisted keys and fingerprints depend on the exact
    /// output bytes, so this rendering must stay byte-identical (see CacheTests'
    /// independent SHA-256 vectors).
    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    package static func sha256(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        // Table-driven hex in a single pass: per-byte String(format:) dominated the
        // identity cost measured in scripts/perf-validation-smoke.swift (M1 split:
        // ~0.4 µs digest vs ~15 µs with per-byte formatting). SHA-256 digests are
        // fixed at 32 bytes, so the capacity is a constant rather than digest.count
        // (ambiguous against the toolchain's count(where:) overload in Swift 5 mode).
        var hex = [UInt8]()
        hex.reserveCapacity(64)
        for byte in digest {
            hex.append(Self.hexDigits[Int(byte >> 4)])
            hex.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }
}
