//
//  G7ShareClient.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  The Share web service as the Dexcom app uses it, from community
//  documentation of its endpoints (StephenBlackWasAlreadyTaken's gist,
//  nightscout/share2nightscout-bridge, and the error codes the service
//  returns to xDrip and xdripswift).
//

import Foundation
import LoopKit
import os.log

/// What the Share service answers with when it refuses: an HTTP 500 with a
/// JSON body `{"Code": ..., "Message": ...}`.
public enum G7ShareError: Error, Equatable {
    case notSignedIn
    case invalidResponse
    case http(status: Int)
    /// The service's own refusal, by its code.
    case service(code: String, message: String?)
    case keychain(OSStatus)

    public var serviceCode: String? {
        if case .service(let code, _) = self { return code }
        return nil
    }

    // Codes the service is known to return.
    public static let sessionNotValid = "SessionNotValid"
    public static let sessionIdNotFound = "SessionIdNotFound"
    public static let accountNotFound = "SSO_AuthenticateAccountNotFound"
    public static let passwordInvalid = "SSO_AuthenticatePasswordInvalid"
    public static let maxAttemptsExceeded = "SSO_AuthenticateMaxAttemptsExceeded"
    public static let receiverNotAssigned = "MonitoredReceiverNotAssigned"
    public static let receiverSerialMismatch = "MonitoredReceiverSerialNumberDoesNotMatch"
    public static let monitoringSessionNotActive = "MonitoringSessionNotActive"
    public static let duplicateEgvPosted = "DuplicateEgvPosted"
    public static let contactNameTaken = "ContactNameAlreadyExists"

    /// CreateContact's refusal when the account already has a contact of
    /// that name ("The contact name already exists for this account").
    public var isContactNameTaken: Bool {
        guard case .service(let code, let message) = self else { return false }
        return code.localizedCaseInsensitiveContains("ContactNameAlreadyExists")
            || code.localizedCaseInsensitiveContains("ContactAlreadyExists")
            || (message ?? "").localizedCaseInsensitiveContains("contact name already exists")
    }

    /// Starting a monitoring session when one is already running is refused
    /// with "Publisher account already has an active monitoring session";
    /// the session is there, which is all that was wanted.
    public var isMonitoringSessionAlreadyActive: Bool {
        guard case .service(let code, let message) = self else { return false }
        return code.localizedCaseInsensitiveContains("AlreadyActive")
            || (message ?? "").localizedCaseInsensitiveContains("already has an active monitoring session")
    }

    /// The code and message together, for the device log.
    public var logDescription: String {
        if case .service(let code, let message) = self {
            return "\(code): \(message ?? "")"
        }
        return localizedDescription
    }

    /// Whether the session id is dead and a fresh login may help.
    public var isSessionExpired: Bool {
        serviceCode == G7ShareError.sessionNotValid || serviceCode == G7ShareError.sessionIdNotFound
    }

    /// Whether the credentials themselves were refused; retrying will not help.
    public var isCredentialsRejected: Bool {
        serviceCode == G7ShareError.accountNotFound || serviceCode == G7ShareError.passwordInvalid || serviceCode == G7ShareError.maxAttemptsExceeded
    }
}

extension G7ShareError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return LocalizedString("Not signed in to Dexcom Share.", comment: "Share error: no credentials")
        case .invalidResponse:
            return LocalizedString("Dexcom Share answered with something unexpected.", comment: "Share error: undecodable response")
        case .http(let status):
            return String(format: LocalizedString("Dexcom Share answered with HTTP %d.", comment: "Share error: HTTP status (1: status code)"), status)
        case .service(let code, let message):
            switch code {
            case G7ShareError.accountNotFound:
                return LocalizedString("Dexcom Share does not know this account name.", comment: "Share error: account not found")
            case G7ShareError.passwordInvalid:
                return LocalizedString("Dexcom Share rejected the password.", comment: "Share error: password invalid")
            case G7ShareError.maxAttemptsExceeded:
                return LocalizedString("Too many sign-in attempts; Dexcom Share has locked the account for a while.", comment: "Share error: max attempts")
            case G7ShareError.receiverNotAssigned, G7ShareError.receiverSerialMismatch:
                return LocalizedString("Dexcom Share does not accept this sensor as the account's device.", comment: "Share error: receiver not assigned")
            default:
                return message ?? code
            }
        case .keychain(let status):
            return String(format: LocalizedString("The credentials could not be stored (%d).", comment: "Share error: keychain status (1: OSStatus)"), Int(status))
        }
    }
}

/// One reading for `PostReceiverEgvRecords`.
public struct G7ShareReading: Equatable {
    public let date: Date
    public let glucose: Int
    public let trend: GlucoseTrend?

    public init(date: Date, glucose: Int, trend: GlucoseTrend?) {
        self.date = date
        self.glucose = glucose
        self.trend = trend
    }

    /// Dexcom's trend ordinals: 1 double up … 7 double down, 8 not computable.
    var trendOrdinal: Int {
        trend?.rawValue ?? 8
    }

    /// `/Date(milliseconds)/`, the service's own date encoding.
    var encodedDate: String {
        "/Date(\(Int64(date.timeIntervalSince1970.rounded()) * 1000))/"
    }

    var json: [String: Any] {
        ["Trend": trendOrdinal, "ST": encodedDate, "DT": encodedDate, "Value": glucose]
    }
}

/// A follower, as the service lists it.
public struct G7ShareFollower: Equatable, Identifiable {
    public let contactId: String
    public let subscriptionId: String?
    public let contactName: String
    public let displayName: String?
    public let state: String?
    public let permissions: Int?

    public var id: String { contactId }
}

/// The alert settings a follower starts with; the follower can change them
/// in the Follow app. Values are mg/dL and ISO 8601 durations.
public struct G7ShareFollowerAlerts: Equatable {
    public var highEnabled = false
    public var highThreshold = 200
    public var lowEnabled = false
    public var lowThreshold = 70
    public var urgentLowEnabled = true
    public var urgentLowThreshold = 55
    public var noDataEnabled = false

    public init() {}

    var json: [String: Any] {
        [
            "HighAlert": ["MinValue": highThreshold, "MaxValue": 401, "AlarmDelay": "PT1H", "RealarmDelay": "PT2H", "AlertType": 1, "IsEnabled": highEnabled, "Sound": "High.wav"],
            "LowAlert": ["MinValue": 39, "MaxValue": lowThreshold, "AlarmDelay": "PT30M", "RealarmDelay": "PT2H", "AlertType": 2, "IsEnabled": lowEnabled, "Sound": "Low.wav"],
            "FixedLowAlert": ["MinValue": 39, "MaxValue": urgentLowThreshold, "AlarmDelay": "PT0M", "RealarmDelay": "PT30M", "AlertType": 3, "IsEnabled": urgentLowEnabled, "Sound": "UrgentLow.wav"],
            "NoDataAlert": ["MinValue": 39, "MaxValue": 401, "AlarmDelay": "PT1H", "RealarmDelay": "PT0M", "AlertType": 4, "IsEnabled": noDataEnabled, "Sound": "NoData.wav"],
        ]
    }
}

/// Talks to the Share service for one account. Signs in on demand and
/// keeps the session id; `sessionId` is nil until the first call.
public final class G7ShareClient {
    private let credentials: G7ShareCredentials
    private let session: URLSession
    private let log = OSLog(category: "G7ShareClient")

    private(set) var sessionId: String?

    /// Receives one line per request and refusal, for the device log. Never
    /// carries credentials or the session id.
    public var logHandler: ((String) -> Void)?

    static let userAgent = "Dexcom Share/3.0.2.11 CFNetwork/711.2.23 Darwin/14.0.0"

    public init(credentials: G7ShareCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    // MARK: - Sign-in

    /// Authenticates and returns the session id. The service takes the
    /// account name (an email works) to answer with an account id, and the
    /// account id with the password to open a session.
    @discardableResult
    public func signIn() async throws -> String {
        let accountId: String = try await post("General/AuthenticatePublisherAccount", body: [
            "accountName": credentials.username,
            "password": credentials.password,
            "applicationId": credentials.server.applicationId,
        ])
        let sessionId: String = try await post("General/LoginPublisherAccountById", body: [
            "accountId": accountId,
            "password": credentials.password,
            "applicationId": credentials.server.applicationId,
        ])
        guard sessionId != "00000000-0000-0000-0000-000000000000" else {
            throw G7ShareError.service(code: G7ShareError.passwordInvalid, message: nil)
        }
        self.sessionId = sessionId
        return sessionId
    }

    func forgetSession() {
        sessionId = nil
    }

    private func requireSession() async throws -> String {
        if let sessionId = sessionId {
            return sessionId
        }
        return try await signIn()
    }

    // MARK: - Uploading

    /// Whether the service has this serial as the account's monitored
    /// device: "AssignedToYou", "NotAssigned", or assigned elsewhere.
    public func receiverAssignment(serial: String) async throws -> String {
        let sessionId = try await requireSession()
        return try await post("Publisher/CheckMonitoredReceiverAssignmentStatus", query: ["sessionId": sessionId, "serialNumber": serial])
    }

    public func assignReceiver(serial: String) async throws {
        let sessionId = try await requireSession()
        try await postExpectingNothing("Publisher/ReplacePublisherAccountMonitoredReceiver", query: ["sessionId": sessionId, "serialNumber": serial])
    }

    public func isRemoteMonitoringSessionActive() async throws -> Bool {
        let sessionId = try await requireSession()
        return try await post("Publisher/IsRemoteMonitoringSessionActive", query: ["sessionId": sessionId])
    }

    public func startRemoteMonitoringSession(serial: String) async throws {
        let sessionId = try await requireSession()
        try await postExpectingNothing("Publisher/StartRemoteMonitoringSession", query: ["sessionId": sessionId, "serialNumber": serial])
    }

    public func postReadings(_ readings: [G7ShareReading], serial: String) async throws {
        let sessionId = try await requireSession()
        try await postExpectingNothing("Publisher/PostReceiverEgvRecords", query: ["sessionId": sessionId], body: G7ShareClient.readingsPayload(readings, serial: serial))
    }

    /// `TA` is what the working uploaders send; the service does not seem to
    /// use it for anything.
    static func readingsPayload(_ readings: [G7ShareReading], serial: String) -> [String: Any] {
        ["SN": serial, "Egvs": readings.map(\.json), "TA": -5]
    }

    // MARK: - Followers

    public func listFollowers() async throws -> [G7ShareFollower] {
        let sessionId = try await requireSession()
        let entries: [[String: Any]] = try await post("Publisher/ListPublisherAccountSubscriptions", query: ["sessionId": sessionId])
        return entries.compactMap { entry in
            guard let contactId = entry["ContactId"] as? String else { return nil }
            return G7ShareFollower(
                contactId: contactId,
                subscriptionId: entry["SubscriptionId"] as? String,
                contactName: entry["ContactName"] as? String ?? "",
                displayName: entry["DisplayName"] as? String,
                state: (entry["State"] as? String) ?? (entry["State"] as? Int).map(String.init),
                permissions: entry["Permissions"] as? Int
            )
        }
    }

    /// Invites someone to follow: a contact is created for them and an
    /// invitation attached to it, which the service emails. Returns the
    /// contact id, which is also what removes them.
    public func inviteFollower(name: String, email: String, displayName: String, alerts: G7ShareFollowerAlerts = G7ShareFollowerAlerts()) async throws -> String {
        let sessionId = try await requireSession()
        let contactId: String
        var createdContact = false
        do {
            contactId = try await post("Publisher/CreateContact", query: ["sessionId": sessionId, "contactName": name, "emailAddress": email])
            createdContact = true
        } catch let error as G7ShareError where error.isContactNameTaken {
            // A contact of that name is already on the account, e.g. from an
            // invitation that did not complete. Reuse it if it can be found.
            guard let existing = try await listFollowers().first(where: { $0.contactName.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw G7ShareError.service(code: G7ShareError.contactNameTaken, message: LocalizedString("A contact with this name already exists on the account but is not among the followers. Use a different name, or remove the contact in the Dexcom app.", comment: "Share error: contact name taken and not listed"))
            }
            logHandler?("Reusing existing contact \(existing.contactId) for \(name)")
            contactId = existing.contactId
        }

        let invitation: [String: Any] = [
            "AlertSettings": alerts.json,
            "Permissions": 1,
            "DisplayName": displayName,
        ]
        do {
            try await createInvitation(contactId: contactId, sessionId: sessionId, body: invitation)
        } catch {
            // A contact that was just created is sometimes not readable for
            // the invitation straight away; give it a moment and try once
            // more before giving up and taking the contact back out, so the
            // name is free for another attempt.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                try await createInvitation(contactId: contactId, sessionId: sessionId, body: invitation)
            } catch {
                if createdContact {
                    logHandler?("Invitation failed; removing the contact just created")
                    try? await removeFollower(contactId: contactId)
                }
                throw error
            }
        }
        return contactId
    }

    private func createInvitation(contactId: String, sessionId: String, body: [String: Any]) async throws {
        let _: String = try await post("Publisher/CreateSubscriptionInvitation", query: ["sessionId": sessionId, "contactId": contactId], body: body)
    }

    public func removeFollower(contactId: String) async throws {
        let sessionId = try await requireSession()
        try await postExpectingNothing("Publisher/DeleteContact", query: ["sessionId": sessionId, "contactId": contactId])
    }

    // MARK: - Transport

    private func request(_ path: String, query: [String: String], body: [String: Any]?) throws -> URLRequest {
        var components = URLComponents(url: credentials.server.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(G7ShareClient.userAgent, forHTTPHeaderField: "User-Agent")
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func send(_ path: String, query: [String: String], body: [String: Any]?) async throws -> Data {
        let request = try self.request(path, query: query, body: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            logHandler?("\(path): no HTTP response")
            throw G7ShareError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let code = object["Code"] as? String {
                let message = object["Message"] as? String ?? ""
                log.error("%{public}@ refused: %{public}@ %{public}@", path, code, message)
                logHandler?("\(path) refused: \(code) \(message)")
                throw G7ShareError.service(code: code, message: object["Message"] as? String)
            }
            logHandler?("\(path): HTTP \(http.statusCode) \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
            throw G7ShareError.http(status: http.statusCode)
        }
        logHandler?("\(path): OK (\(data.count) bytes)")
        return data
    }

    private func post<T>(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> T {
        let data = try await send(path, query: query, body: body)
        guard let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? T else {
            throw G7ShareError.invalidResponse
        }
        return value
    }

    private func postExpectingNothing(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws {
        _ = try await send(path, query: query, body: body)
    }
}
