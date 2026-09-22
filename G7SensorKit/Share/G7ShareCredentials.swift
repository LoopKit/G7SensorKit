//
//  G7ShareCredentials.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import Security

/// The Dexcom Share regions. Each has its own host; Japan also has its own
/// application identifier.
public enum G7ShareServer: String, CaseIterable, Equatable {
    case us
    case worldwide
    case japan

    public var baseURL: URL {
        switch self {
        case .us: return URL(string: "https://share2.dexcom.com/ShareWebServices/Services")!
        case .worldwide: return URL(string: "https://shareous1.dexcom.com/ShareWebServices/Services")!
        case .japan: return URL(string: "https://share.dexcom.jp/ShareWebServices/Services")!
        }
    }

    /// The identifier the Dexcom app presents to the Share service.
    var applicationId: String {
        switch self {
        case .us, .worldwide: return "d89443d2-327c-4a6f-89e5-496bbb0317db"
        case .japan: return "d8665ade-9673-4e27-9ff6-92db4ce13d13"
        }
    }

    public var localizedName: String {
        switch self {
        case .us: return LocalizedString("United States", comment: "Dexcom Share server region")
        case .worldwide: return LocalizedString("Outside the United States", comment: "Dexcom Share server region")
        case .japan: return LocalizedString("Japan", comment: "Dexcom Share server region")
        }
    }
}

public struct G7ShareCredentials: Equatable {
    public let username: String
    public let password: String
    public let server: G7ShareServer

    public init(username: String, password: String, server: G7ShareServer) {
        self.username = username
        self.password = password
        self.server = server
    }
}

/// Keeps the Share password in the keychain. Only the username and server
/// live in the manager's state, which the host persists unencrypted.
struct G7ShareCredentialStore {
    static let service = "org.loopkit.G7SensorKit.dexcomShare"
    static let account = "dexcom-share"

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: G7ShareCredentialStore.service,
            kSecAttrAccount as String: G7ShareCredentialStore.account,
        ]
    }

    func save(_ credentials: G7ShareCredentials) throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "username": credentials.username,
            "password": credentials.password,
            "server": credentials.server.rawValue,
        ])
        var attributes = query
        attributes[kSecValueData as String] = payload
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw G7ShareError.keychain(status)
        }
    }

    func load() -> G7ShareCredentials? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let username = object["username"], let password = object["password"],
              let server = object["server"].flatMap(G7ShareServer.init(rawValue:))
        else {
            return nil
        }
        return G7ShareCredentials(username: username, password: password, server: server)
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
