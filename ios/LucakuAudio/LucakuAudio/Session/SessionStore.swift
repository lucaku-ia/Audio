import Foundation
import Security

/// Posted by `APIClient` whenever any request comes back `401` — the token
/// was rejected (expired, revoked by a server-side logout elsewhere,
/// `token_version` bumped). `SessionStore` observes this itself so a stale
/// session gets cleared and `ContentView` routes back to `LoginView`
/// automatically, no matter which screen/call triggered the 401.
///
/// Before this existed, `SessionStore.clear()` was only ever called from the
/// manual Settings "Log out" button — an expired token left every other
/// screen stuck showing a generic "not signed in" error forever, since
/// nothing else route back to Login. Found in the 2026-09-18 architecture
/// review, fixed here.
extension Notification.Name {
    static let sessionExpired = Notification.Name("com.lucaku.audio.sessionExpired")
}

/// Holds the signed-in customer's bearer token in memory and mirrors it to
/// the Keychain so it survives an app relaunch.
///
/// Deliberately minimal: this scaffold's job is proving the request/decode
/// path end to end, not building a full session/token-refresh system (the
/// backend's JWT doesn't support refresh — see backend/app/core/security.py;
/// `logout` just bumps `token_version` server-side to invalidate everything
/// issued before it).
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var accessToken: String?

    private let keychainKey = "com.lucaku.audio.accessToken"
    private var sessionExpiredObserver: NSObjectProtocol?

    init() {
        accessToken = KeychainHelper.read(key: keychainKey)

        // `queue: .main` delivers this on the main thread, matching this
        // @MainActor class's own isolation — see the Notification.Name
        // extension above for why this exists.
        sessionExpiredObserver = NotificationCenter.default.addObserver(
            forName: .sessionExpired, object: nil, queue: .main
        ) { [weak self] _ in
            self?.clear()
        }
    }

    deinit {
        if let sessionExpiredObserver {
            NotificationCenter.default.removeObserver(sessionExpiredObserver)
        }
    }

    var isAuthenticated: Bool { accessToken != nil }

    func store(token: String) {
        accessToken = token
        KeychainHelper.save(key: keychainKey, value: token)
    }

    func clear() {
        accessToken = nil
        KeychainHelper.delete(key: keychainKey)
    }
}

/// A tiny Keychain wrapper — just enough to persist one string. No
/// third-party dependency needed for this.
enum KeychainHelper {
    static func save(key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
