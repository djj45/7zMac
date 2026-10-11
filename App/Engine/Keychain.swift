import Foundation
import Security

/// 把“固定压缩密码”存在钥匙串里（不放在 UserDefaults 明文中）
enum Keychain {
    private static let service = "local.djj45.7zmac"
    private static let account = "compress-password"

    static func loadPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func savePassword(_ password: String?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let password, !password.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
