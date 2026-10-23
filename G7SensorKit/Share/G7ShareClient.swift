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

    /// The account's monitored device is not this serial, e.g. after a
    /// sensor change.
    public var isReceiverRefused: Bool {
        serviceCode == G7ShareError.receiverNotAssigned || serviceCode == G7ShareError.receiverSerialMismatch
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

    /// Makes this serial the account's monitored device, replacing whatever
    /// was registered before.
    public func assignReceiver(serial: String) async throws {
        let sessionId = try await requireSession()
        try await postExpectingNothing("Publisher/ReplacePublisherAccountMonitoredReceiver", query: ["sessionId": sessionId, "serialNumber": serial])
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
