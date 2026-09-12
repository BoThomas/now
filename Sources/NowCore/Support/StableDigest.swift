import Foundation
#if os(macOS)
import CryptoKit
#else
import Crypto
#endif

/// Persisted identities use SHA-256 over the exact UTF-8 bytes, never Swift Hasher.
/// Apple retains CryptoKit; other supported hosts use the pinned Swift Crypto API.
package enum StableDigest {
    package static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
