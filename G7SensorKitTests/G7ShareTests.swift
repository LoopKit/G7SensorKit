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

    func testFollowerAlertsPayload() {
        var alerts = G7ShareFollowerAlerts()
        alerts.lowEnabled = true
        alerts.lowThreshold = 80
        let json = alerts.json
        let low = json["LowAlert"] as? [String: Any]
        XCTAssertEqual(low?["IsEnabled"] as? Bool, true)
        XCTAssertEqual(low?["MaxValue"] as? Int, 80)
        XCTAssertEqual((json["FixedLowAlert"] as? [String: Any])?["IsEnabled"] as? Bool, true)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(json))
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
        XCTAssertTrue(G7ShareError.service(code: "Unknown", message: "The contact name already exists for this account.").isContactNameTaken)
        XCTAssertTrue(G7ShareError.service(code: "ContactNameAlreadyExists", message: nil).isContactNameTaken)
        XCTAssertTrue(G7ShareError.service(code: "ContactIdNotFound", message: "Failed to read Contact by id.").isContactNotFound)
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
}
