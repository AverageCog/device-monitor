import Foundation
import Security
import os

/// Where the enrollment lives. The app uses `KeychainCredentialStore`; tests, previews and demo
/// mode use `InMemoryCredentialStore`.
public protocol CredentialStore: Sendable {
    /// The stored enrollment, or nil when the app is not paired.
    func load() throws -> Enrollment?
    /// Replaces the stored enrollment in one step: a reader sees the old value or the new one.
    func save(_ enrollment: Enrollment) throws
    /// Forgets the enrollment. Succeeds when there is none.
    func clear() throws
}

public enum CredentialStoreError: Error, Equatable, Sendable, LocalizedError {
    /// A Keychain call failed with this `OSStatus`.
    case keychain(status: Int32)
    /// The stored item is not a valid enrollment (for example written by an incompatible build).
    case corrupted

    public var errorDescription: String? {
        switch self {
        case .keychain(let status): "The Keychain is unavailable (error \(status))."
        case .corrupted: "The saved hub connection is unreadable. Pair with the hub again."
        }
    }
}

public final class InMemoryCredentialStore: CredentialStore {
    private let state: OSAllocatedUnfairLock<Enrollment?>

    public init(_ enrollment: Enrollment? = nil) {
        state = OSAllocatedUnfairLock(initialState: enrollment)
    }

    public func load() throws -> Enrollment? { state.withLock { $0 } }
    public func save(_ enrollment: Enrollment) throws { state.withLock { $0 = enrollment } }
    public func clear() throws { state.withLock { $0 = nil } }
}

/// One generic-password item holding the JSON-encoded enrollment.
///
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable by a background refresh once the
///   phone has been unlocked after boot, and never restored onto another device.
/// - Not synchronizable: it never reaches iCloud Keychain.
public struct KeychainCredentialStore: CredentialStore {
    public static let defaultService = "com.devicemonitor.ios.enrollment"

    private let service: String
    private let account: String

    public init(service: String = KeychainCredentialStore.defaultService, account: String = "hub") {
        self.service = service
        self.account = account
    }

    private var item: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
            // macOS only has the iOS item semantics (and accessibility classes) in this keychain.
            kSecUseDataProtectionKeychain: true,
        ]
    }

    public func load() throws -> Enrollment? {
        var query = item
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status: status) }
        guard let data = result as? Data else { throw CredentialStoreError.corrupted }
        return try Self.decode(data)
    }

    public func save(_ enrollment: Enrollment) throws {
        let data = try Self.encode(enrollment)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        // Updating in place is atomic; delete-then-add would leave a window with no enrollment.
        var status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item.merging(attributes) { _, new in new } as CFDictionary, nil)
            if status == errSecDuplicateItem { status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary) }
        }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status: status) }
    }

    public func clear() throws {
        let status = SecItemDelete(item as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status: status) }
    }

    /// The bytes stored in the Keychain item.
    static func encode(_ enrollment: Enrollment) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(enrollment)
    }

    static func decode(_ data: Data) throws -> Enrollment {
        // Decoding errors can quote the offending value, which may be a secret: never surface them.
        guard let enrollment = try? JSONDecoder().decode(Enrollment.self, from: data) else { throw CredentialStoreError.corrupted }
        return enrollment
    }
}
