import Foundation
import Security
import CryptoKit

enum Files {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LFAZVideos", isDirectory: true)
    static func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var mutable = url; try? mutable.setResourceValues(values)
        return url
    }
    static func key(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: Data(contentsOf: root.appendingPathComponent(name)))
    }
    static func save<T: Encodable>(_ value: T, name: String) throws {
        _ = try folder("")
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum AccountKeychain {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "LFaz.Videos.NAS", kSecAttrAccount as String: "primary"] }
    static func save(_ account: NASAccount) throws {
        let data = try JSONEncoder().encode(account)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw VideoError.message("No se pudo guardar la cuenta en el llavero del iPhone.") }
    }
    static func load() -> NASAccount? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(NASAccount.self, from: data)
    }
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VideoError.message("No se pudo eliminar la cuenta del llavero.") }
    }
}
