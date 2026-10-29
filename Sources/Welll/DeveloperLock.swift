import CryptoKit
import Foundation

/// Gates the developer page. The password is kept as a SHA-256 digest rather than plain
/// text. This keeps casual users out but isn't security: anyone with the app can patch it.
/// To change the password, run  echo -n 'new password' | shasum -a 256  and paste the result.
enum DeveloperLock {
    private static let digest = "96cae35ce8a9b0244178bf28e4966c2ce1b8385723a96a6b838858cdd6ca0a1e"

    static func matches(_ candidate: String) -> Bool {
        let hash = SHA256.hash(data: Data(candidate.utf8))
        return hash.map { String(format: "%02x", $0) }.joined() == digest
    }
}
