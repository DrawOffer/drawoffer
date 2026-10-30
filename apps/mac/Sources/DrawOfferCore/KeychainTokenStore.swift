import Foundation
import Security
import LocalAuthentication

public struct KeychainStoreError: Error, Sendable {
    public let status: OSStatus
}

/// One encoded record per origin/channel/app. Never delete before replacing it.
public struct KeychainTokenStore: TokenStore {
    private let service: String

    // Pre-rename keychain name; changing it would sign existing users out.
    public init(service: String = "com.linkresume.desktop.credentials") {
        self.service = service
    }

    private func query(_ scope: String) -> [CFString: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: scope, kSecAttrSynchronizable: false,
         kSecUseAuthenticationContext: context]
    }

    public func load(scope: String) throws -> DesktopCredentialRecord? {
        var query = query(scope)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError(status: status) }
        guard let data = result as? Data else { throw APIError.invalidResponse }
        return try JSONDecoder().decode(DesktopCredentialRecord.self, from: data)
    }

    public func save(_ record: DesktopCredentialRecord, scope: String) throws {
        let attributes: [CFString: Any] = [kSecValueData: try JSONEncoder().encode(record),
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query(scope) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query(scope).merging(attributes) { _, new in new }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainStoreError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainStoreError(status: status)
        }
    }

    public func clear(scope: String) throws {
        let status = SecItemDelete(query(scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(status: status)
        }
    }
}


/// 仅本地对照调试用：凭据存进指定目录下权限 0600 的文件，不访问系统钥匙串。
/// 每次本地重新构建的 ad-hoc 签名都不同，用钥匙串会让系统反复弹出授权框。正式 App 不使用它。
public struct LocalFileTokenStore: TokenStore {
    private let directory: URL

    public init(directory: URL) { self.directory = directory }

    private func file(_ scope: String) -> URL {
        let name = scope.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return directory.appendingPathComponent("credential-\(name).json")
    }

    public func load(scope: String) throws -> DesktopCredentialRecord? {
        guard let data = try? Data(contentsOf: file(scope)) else { return nil }
        return try JSONDecoder().decode(DesktopCredentialRecord.self, from: data)
    }

    public func save(_ record: DesktopCredentialRecord, scope: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = file(scope)
        try JSONEncoder().encode(record).write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    public func clear(scope: String) throws {
        let target = file(scope)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }
}
