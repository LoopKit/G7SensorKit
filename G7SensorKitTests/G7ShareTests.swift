//
//  G7ShareTests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import LoopKit
@testable import G7SensorKit

final class G7ShareTests: XCTestCase {

    func testReadingEncoding() {
        let reading = G7ShareReading(date: Date(timeIntervalSince1970: 1_700_000_000.4), glucose: 123, trend: .up)
        let json = reading.json
        XCTAssertEqual(json["Trend"] as? Int, 3)
        XCTAssertEqual(json["ST"] as? String, "/Date(1700000000000)/")
        XCTAssertEqual(json["DT"] as? String, "/Date(1700000000000)/")
        XCTAssertEqual(json["Value"] as? Int, 123)
        XCTAssertEqual(G7ShareReading(date: Date(), glucose: 100, trend: nil).trendOrdinal, 8, "unknown trend is Dexcom's 'not computable'")
        XCTAssertEqual(G7ShareReading(date: Date(), glucose: 100, trend: .downDownDown).trendOrdinal, 7)
    }

    func testReadingsPayload() throws {
        let payload = G7ShareClient.readingsPayload([G7ShareReading(date: Date(timeIntervalSince1970: 1_700_000_000), glucose: 99, trend: .flat)], serial: "123456789012")
        XCTAssertEqual(payload["SN"] as? String, "123456789012")
        XCTAssertEqual(payload["TA"] as? Int, -5)
        XCTAssertEqual((payload["Egvs"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(payload))
    }

    func testServiceErrorClassification() {
        XCTAssertTrue(G7ShareError.service(code: "SessionNotValid", message: nil).isSessionExpired)
        XCTAssertTrue(G7ShareError.service(code: "SessionIdNotFound", message: nil).isSessionExpired)
        XCTAssertTrue(G7ShareError.service(code: "SSO_AuthenticatePasswordInvalid", message: nil).isCredentialsRejected)
        XCTAssertFalse(G7ShareError.service(code: "DuplicateEgvPosted", message: nil).isSessionExpired)
        XCTAssertNil(G7ShareError.http(status: 503).serviceCode)
        XCTAssertTrue(G7ShareError.service(code: "MonitoringSessionAlreadyActive", message: nil).isMonitoringSessionAlreadyActive)
        XCTAssertTrue(G7ShareError.service(code: "Unknown", message: "Publisher account already has an active monitoring session.").isMonitoringSessionAlreadyActive)
        XCTAssertFalse(G7ShareError.service(code: "MonitoringSessionNotActive", message: nil).isMonitoringSessionAlreadyActive)
        XCTAssertTrue(G7ShareError.service(code: "MonitoredReceiverNotAssigned", message: nil).isReceiverRefused)
        XCTAssertTrue(G7ShareError.service(code: "MonitoredReceiverSerialNumberDoesNotMatch", message: nil).isReceiverRefused)
        XCTAssertFalse(G7ShareError.service(code: "SessionNotValid", message: nil).isReceiverRefused)
    }

    func testServers() {
        XCTAssertEqual(G7ShareServer.us.baseURL.host, "share2.dexcom.com")
        XCTAssertEqual(G7ShareServer.worldwide.baseURL.host, "shareous1.dexcom.com")
        XCTAssertEqual(G7ShareServer.japan.baseURL.host, "share.dexcom.jp")
        XCTAssertNotEqual(G7ShareServer.japan.applicationId, G7ShareServer.us.applicationId)
    }

    func testShareStateRoundTrips() {
        var state = G7CGMManagerState()
        state.shareUsername = "pete"
        state.shareServer = .worldwide
        state.shareUploadedThrough = Date(timeIntervalSince1970: 1_700_000_000)
        state.shareLastError = "SessionNotValid"
        let restored = G7CGMManagerState(rawValue: state.rawValue)
        XCTAssertEqual(restored.shareUsername, "pete")
        XCTAssertEqual(restored.shareServer, .worldwide)
        XCTAssertEqual(restored.shareUploadedThrough, state.shareUploadedThrough)
        XCTAssertEqual(restored.shareLastError, "SessionNotValid")
        XCTAssertTrue(PropertyListSerialization.propertyList(state.rawValue, isValidFor: .binary))
    }

    // MARK: - Upload flow

    override func tearDown() {
        G7ShareStubProtocol.responses = []
        G7ShareStubProtocol.requestedPaths = []
        super.tearDown()
    }

    func testUploadPostsWithoutRegisteringFirst() {
        G7ShareStubProtocol.responses = [.string("account"), .string("session"), .empty]
        let status = runUpload()
        XCTAssertNotNil(status.lastUploadAt)
        XCTAssertEqual(G7ShareStubProtocol.requestedPaths, [
            "General/AuthenticatePublisherAccount",
            "General/LoginPublisherAccountById",
            "Publisher/PostReceiverEgvRecords",
        ])
    }

    func testUploadRegistersSensorAndStartsMonitoringOnlyWhenRefused() {
        G7ShareStubProtocol.responses = [
            .string("account"), .string("session"),
            .refusal("MonitoredReceiverNotAssigned"), .empty,
            .refusal("MonitoringSessionNotActive"), .empty,
            .empty,
        ]
        let status = runUpload()
        XCTAssertNotNil(status.lastUploadAt)
        XCTAssertEqual(G7ShareStubProtocol.requestedPaths, [
            "General/AuthenticatePublisherAccount",
            "General/LoginPublisherAccountById",
            "Publisher/PostReceiverEgvRecords",
            "Publisher/ReplacePublisherAccountMonitoredReceiver",
            "Publisher/PostReceiverEgvRecords",
            "Publisher/StartRemoteMonitoringSession",
            "Publisher/PostReceiverEgvRecords",
        ])
    }

    func testUploadRegistersSensorOnlyOnce() {
        G7ShareStubProtocol.responses = [
            .string("account"), .string("session"),
            .refusal("MonitoredReceiverNotAssigned"), .empty,
            .refusal("MonitoredReceiverNotAssigned"),
        ]
        let status = runUpload()
        XCTAssertNil(status.lastUploadAt)
        XCTAssertNotNil(status.lastError)
        XCTAssertEqual(G7ShareStubProtocol.requestedPaths.filter { $0 == "Publisher/ReplacePublisherAccountMonitoredReceiver" }.count, 1)
    }

    func testUploadSignsInAgainWhenSessionLapses() {
        G7ShareStubProtocol.responses = [
            .string("account"), .string("session"),
            .refusal("SessionNotValid"),
            .string("account"), .string("session2"),
            .empty,
        ]
        let status = runUpload()
        XCTAssertNotNil(status.lastUploadAt)
        XCTAssertEqual(G7ShareStubProtocol.requestedPaths.filter { $0 == "Publisher/PostReceiverEgvRecords" }.count, 2)
    }

    private func runUpload() -> G7ShareUploadStatus {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [G7ShareStubProtocol.self]
        let client = G7ShareClient(credentials: G7ShareCredentials(username: "user", password: "pass", server: .us), session: URLSession(configuration: configuration))
        let uploader = G7ShareUploader(client: client, uploadedThrough: nil)
        uploader.serial = "123456789012"
        let finished = expectation(description: "upload finished")
        var result = G7ShareUploadStatus()
        uploader.onStatusChange = { status, _ in
            guard status.lastUploadAt != nil || status.lastError != nil else { return }
            result = status
            finished.fulfill()
        }
        uploader.enqueue([G7ShareReading(date: Date(), glucose: 120, trend: .flat)])
        wait(for: [finished], timeout: 5)
        return result
    }
}

/// Answers Share requests from a script, in order, and records their paths.
final class G7ShareStubProtocol: URLProtocol {
    enum Response {
        case string(String)
        case empty
        case refusal(String)
    }

    static var responses: [Response] = []
    static var requestedPaths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let components = request.url?.pathComponents ?? []
        G7ShareStubProtocol.requestedPaths.append(components.suffix(2).joined(separator: "/"))
        let next = G7ShareStubProtocol.responses.isEmpty ? .refusal("UnexpectedRequest") : G7ShareStubProtocol.responses.removeFirst()
        let status: Int
        let body: Data
        switch next {
        case .string(let value):
            status = 200
            body = try! JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
        case .empty:
            status = 200
            body = Data()
        case .refusal(let code):
            status = 500
            body = try! JSONSerialization.data(withJSONObject: ["Code": code, "Message": ""])
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
