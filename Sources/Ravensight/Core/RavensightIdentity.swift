import CryptoKit
import Foundation

/// The pure parts of identify: validation, the salted hash, and what each
/// answer means. The client owns the state and the timing.
enum RavensightIdentity {
    /// The longest account id accepted, in UTF-8 bytes.
    static let maxBytes = 256

    /// The refusal code for an account id, or nil when it may be used. The id
    /// is checked exactly as given: never trimmed or normalised.
    static func refusal(_ accountId: String) -> String? {
        if accountId.isEmpty { return "empty" }
        if accountId.utf8.count > maxBytes { return "too_long" }
        if accountId.contains("@") { return "looks_like_email" }
        return nil
    }

    /// Lower case hex HMAC-SHA256 keyed with the UTF-8 bytes of the salt
    /// string exactly as the session answer gave it (not hex decoded), over
    /// the UTF-8 bytes of the account id.
    static func accountHash(accountId: String, salt: String) -> String {
        let key = SymmetricKey(data: Data(salt.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(accountId.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// The salt in a session answer (identify.salt), or nil when the server
    /// does not offer identify.
    static func salt(in answer: [String: Any]?) -> String? {
        guard let identify = answer?["identify"] as? [String: Any],
              let salt = identify["salt"] as? String, !salt.isEmpty else { return nil }
        return salt
    }

    /// What an identify answer means for the next attempt.
    enum Outcome: Equatable {
        /// Done for this session (200).
        case done
        /// Not again this session; the next session tries again.
        case nextSession
        /// Not again this launch (404, or a hash the server calls invalid).
        case stopForLaunch
    }

    static func outcome(status: Int, error: String) -> Outcome {
        switch status {
        case 200..<300: return .done
        case 404: return .stopForLaunch
        case 400 where error == "invalid_account_hash": return .stopForLaunch
        default: return .nextSession
        }
    }
}
