import CryptoKit
import Foundation
import Security

/// 128-bit pre-shared key used for TLS-PSK between the Mac app and the iPhone viewer.
public struct PairingKey: Equatable, Sendable {
    public let bytes: Data

    public static func generate() -> PairingKey {
        PairingKey(bytes: SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
    }

    init(bytes: Data) { self.bytes = bytes }

    /// Accepts the displayed form (`ABCD-EF01-…`) or any pasted text containing 32 hex digits.
    public init?(string: String) {
        let hex = string.filter(\.isHexDigit)
        guard hex.count == 32 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self.bytes = data
    }

    /// `ABCD-EF01-…`, eight groups of four hex digits.
    public var display: String {
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { start -> String in
            let from = hex.index(hex.startIndex, offsetBy: start)
            return String(hex[from ..< hex.index(from, offsetBy: 4)])
        }.joined(separator: "-")
    }
}

/// Minimal generic-password Keychain wrapper for the pairing key.
public enum KeychainStore {
    private static let service = "com.pcmenke.applepolish.pairing"

    public static func save(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    public static func load(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}
