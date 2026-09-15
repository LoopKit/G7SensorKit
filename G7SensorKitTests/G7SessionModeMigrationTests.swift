//
//  G7SessionModeMigrationTests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import CoreBluetooth
import LoopKit
@testable import G7SensorKit

/// CBCentralManager with the state restoration option raises an exception in a
/// test bundle, which lacks the bluetooth-central background mode.
private class TestBluetoothManager: G7BluetoothManager {
    override func makeCentralManager(queue: DispatchQueue) -> CBCentralManager {
        return CBCentralManager(delegate: self, queue: queue)
    }
}

/// Someone upgrading mid-session may have applied their sensor days ago and no
/// longer have its pairing code, so the upgrade must not strand them: restored
/// state that predates direct pairing has to keep working exactly as before.
final class G7SessionModeMigrationTests: XCTestCase {

    /// Raw state as written by a version of the plugin with no notion of
    /// pairing: no mode, no code, no key.
    private var legacyRawState: G7CGMManagerState.RawValue {
        [
            "sensorID": "DXCM99",
            "activatedAt": Date(timeIntervalSinceNow: -54000),
            "latestConnect": Date(timeIntervalSinceNow: -300),
            "uploadReadings": true
        ]
    }

    /// Every manager here goes through the internal initializer with the
    /// bluetooth seam: the public ones build a real central manager, which
    /// CoreBluetooth refuses to do in a test bundle.
    private func makeManager(state: G7CGMManagerState) -> G7CGMManager {
        G7CGMManager(state: state, sensor: makeSensor(state.sessionMode, state.sensorCredentials))
    }

    private func makeSensor(_ mode: G7SessionMode, _ credentials: G7SensorCredentials) -> G7Sensor {
        G7Sensor(mode: mode, credentials: credentials, bluetoothManager: TestBluetoothManager())
    }

    /// The state `G7CGMManager(pairingCode:peripheralIdentifier:sharedKey:)` starts from.
    private func pairedState(pairingCode: String, peripheralIdentifier: UUID, sharedKey: Data?) -> G7CGMManagerState {
        var state = G7CGMManagerState()
        state.sessionMode = .direct
        state.pairingCode = pairingCode
        state.peripheralIdentifier = peripheralIdentifier
        state.sharedKey = sharedKey
        return state
    }

    // MARK: - State

    func testLegacyStateRestoresAsEavesdropping() {
        let state = G7CGMManagerState(rawValue: legacyRawState)
        XCTAssertEqual(state.sessionMode, .eavesdropping)
        XCTAssertNil(state.pairingCode)
        XCTAssertNil(state.sharedKey)
        XCTAssertNil(state.peripheralIdentifier)
        // The rest of the session survives untouched.
        XCTAssertEqual(state.sensorID, "DXCM99")
    }

    func testEavesdroppingModeRequiresTheDexcomApp() {
        XCTAssertTrue(G7SessionMode.eavesdropping.requiresDexcomApp)
        XCTAssertFalse(G7SessionMode.direct.requiresDexcomApp)
    }

    func testDirectStateRoundTrips() {
        let identifier = UUID()
        var state = G7CGMManagerState()
        state.sessionMode = .direct
        state.pairingCode = "1155"
        state.sharedKey = Data(repeating: 0xAB, count: 16)
        state.peripheralIdentifier = identifier
        state.sensorID = "DXCM99"

        let restored = G7CGMManagerState(rawValue: state.rawValue)
        XCTAssertEqual(restored.sessionMode, .direct)
        XCTAssertEqual(restored.pairingCode, "1155")
        XCTAssertEqual(restored.sharedKey, Data(repeating: 0xAB, count: 16))
        XCTAssertEqual(restored.peripheralIdentifier, identifier)
        XCTAssertEqual(restored, state)
    }

    /// The raw state goes into a plist, so every value has to be a property
    /// list type or the whole manager fails to persist.
    func testRawStateIsPropertyListCompatible() {
        var state = G7CGMManagerState()
        state.sessionMode = .direct
        state.pairingCode = "1155"
        state.sharedKey = Data(repeating: 0xAB, count: 16)
        state.peripheralIdentifier = UUID()
        state.sensorID = "DXCM99"
        state.activatedAt = Date()

        XCTAssertTrue(PropertyListSerialization.propertyList(state.rawValue, isValidFor: .binary))
    }

    // MARK: - Manager

    func testLegacyManagerRestoresIntoEavesdroppingMode() {
        let manager = makeManager(state: G7CGMManagerState(rawValue: legacyRawState))
        XCTAssertEqual(manager.sessionMode, .eavesdropping)
        XCTAssertEqual(manager.sensor.mode, .eavesdropping)
        XCTAssertEqual(manager.state.sensorID, "DXCM99")
    }

    func testFreshStateIsEavesdropping() {
        let manager = makeManager(state: G7CGMManagerState())
        XCTAssertEqual(manager.sessionMode, .eavesdropping)
        XCTAssertEqual(manager.sensor.mode, .eavesdropping)
    }

    func testPairedStateIsDirect() {
        let identifier = UUID()
        let key = Data(repeating: 0x11, count: 16)
        let manager = makeManager(state: pairedState(pairingCode: "1155", peripheralIdentifier: identifier, sharedKey: key))

        XCTAssertEqual(manager.sessionMode, .direct)
        XCTAssertEqual(manager.sensor.mode, .direct)
        XCTAssertEqual(manager.state.pairingCode, "1155")
        XCTAssertEqual(manager.state.sharedKey, key)
        XCTAssertEqual(manager.state.peripheralIdentifier, identifier)
        XCTAssertEqual(manager.sensor.credentials, manager.state.sensorCredentials)
    }

    /// The upgrade path: an eavesdropping session pairs, and from then on the
    /// Dexcom app is not involved.
    func testApplyPairingResultUpgradesAnEavesdroppingSession() {
        var state = G7CGMManagerState(rawValue: legacyRawState)
        let manager = makeManager(state: state)
        let before = manager.sensor
        XCTAssertEqual(manager.sensor.mode, .eavesdropping)

        let identifier = UUID()
        let key = Data(repeating: 0x22, count: 16)
        manager.applyPairingResult(pairingCode: "0420", peripheralIdentifier: identifier, sharedKey: key)

        XCTAssertEqual(manager.sessionMode, .direct)
        XCTAssertEqual(manager.sensor.mode, .direct)
        XCTAssertTrue(manager.sensor === before, "the session and its Bluetooth central survive; only the mode changes")
        XCTAssertEqual(manager.sensor.credentials, manager.state.sensorCredentials)
        XCTAssertEqual(manager.state.pairingCode, "0420")
        XCTAssertEqual(manager.state.sharedKey, key)
        XCTAssertEqual(manager.state.peripheralIdentifier, identifier)

        // Without a name for the paired sensor its identity is dropped: which
        // sensor was actually paired is only knowable once it reports a reading.
        XCTAssertNil(manager.state.sensorID)
        XCTAssertNil(manager.state.activatedAt)
        XCTAssertNil(manager.state.latestReading)
        XCTAssertEqual(manager.state.previousSensor?.sensorID, "DXCM99")
    }

    func testPairingWithTheSensorAlreadyFollowedKeepsItsSession() {
        var state = G7CGMManagerState(rawValue: legacyRawState)
        state.latestReading = G7GlucoseMessage(data: Data(hexadecimalString: "4e0098a400008e000001f500700006016f000f")!)
        state.latestReadingTimestamp = Date(timeIntervalSinceNow: -120)
        state.lifecycleAlertsScheduledFor = "DXCM99|1"
        state.sensorEndRecordedFor = nil
        let manager = makeManager(state: state)
        let activatedAt = state.activatedAt

        // Once connected the sensor calls itself "Dexcom99", not "DXCM99".
        manager.applyPairingResult(pairingCode: "0420", peripheralIdentifier: UUID(), sharedKey: Data(repeating: 3, count: 16), sensorName: "Dexcom99")

        XCTAssertEqual(manager.sessionMode, .direct)
        XCTAssertEqual(manager.state.sensorID, "DXCM99")
        XCTAssertEqual(manager.state.activatedAt, activatedAt)
        XCTAssertNotNil(manager.state.latestReading)
        XCTAssertEqual(manager.state.lifecycleAlertsScheduledFor, "DXCM99|1", "the alerts already scheduled for this sensor still stand")
        XCTAssertNil(manager.state.previousSensor, "the same sensor is not its own predecessor")
        XCTAssertNil(manager.state.sensorEndRecordedFor, "its session did not end")
        XCTAssertNotNil(manager.state.pairedAt)
    }

    func testBackfillFramesCarryOneOrTwoRecords() {
        let sensor = makeSensor(.direct, G7SensorCredentials(sensorID: "DXCM99", pairingCode: "0420", sharedKey: nil, peripheralIdentifier: nil))
        let delegate = BackfillRecordingDelegate()
        sensor.delegate = delegate

        // A G7 packs two 9-byte records into one notification; the ONE+ sends one.
        sensor.bluetoothManager(sensor.bluetoothManager, didReceiveBackfillResponse: Data(hexadecimalString: "cf5802008f00060f10" + "f20e0d00ba00060ffb")!)
        sensor.bluetoothManager(sensor.bluetoothManager, didReceiveBackfillResponse: Data(hexadecimalString: "f63d00008500061efe")!)
        // Not a record frame.
        sensor.bluetoothManager(sensor.bluetoothManager, didReceiveBackfillResponse: Data(hexadecimalString: "0102030405")!)
        sensor.flushBackfillBuffer()

        wait(for: [delegate.backfillArrived], timeout: 2)
        XCTAssertEqual(delegate.backfill.map(\.timestamp), [153807, 855794, 15862])
    }

    func testPairingWithADifferentSensorReplacesTheFollowedOne() {
        let state = G7CGMManagerState(rawValue: legacyRawState)
        let manager = makeManager(state: state)

        manager.applyPairingResult(pairingCode: "0420", peripheralIdentifier: UUID(), sharedKey: Data(repeating: 3, count: 16), sensorName: "DXCMzz")

        XCTAssertNil(manager.state.sensorID)
        XCTAssertEqual(manager.state.previousSensor?.sensorID, "DXCM99")
        XCTAssertEqual(manager.state.previousSensor?.endReason, .replaced)
    }

    func testApplyPairingResultCancelsAPendingSessionEndGracePeriod() {
        var state = G7CGMManagerState(rawValue: legacyRawState)
        state.suspectedSessionEndAt = Date()
        let manager = makeManager(state: state)

        manager.applyPairingResult(pairingCode: "0420", peripheralIdentifier: UUID(), sharedKey: Data(repeating: 1, count: 16))

        XCTAssertNil(manager.state.suspectedSessionEndAt)
    }

    /// A code and key only ever authenticate the sensor they came from, so
    /// looking for a new one has to discard them; otherwise every candidate
    /// fails its handshake and the sensor is never adopted.
    func testScanningForANewSensorDiscardsPairingCredentials() {
        let manager = makeManager(state: pairedState(
            pairingCode: "1155",
            peripheralIdentifier: UUID(),
            sharedKey: Data(repeating: 0x33, count: 16)
        ))

        manager.scanForNewSensor()

        XCTAssertNil(manager.state.pairingCode)
        XCTAssertNil(manager.state.sharedKey)
        XCTAssertNil(manager.state.peripheralIdentifier)
        XCTAssertNil(manager.state.sensorID)
        // Still a direct-mode manager: the user has not gone back to the
        // Dexcom app, they just need to pair the replacement.
        XCTAssertEqual(manager.sessionMode, .direct)
    }

    func testInvalidatingTheSharedKeyKeepsThePairingCode() {
        let manager = makeManager(state: pairedState(
            pairingCode: "1155",
            peripheralIdentifier: UUID(),
            sharedKey: Data(repeating: 0x44, count: 16)
        ))

        manager.sensorDidInvalidateSharedKey(manager.sensor)

        XCTAssertNil(manager.state.sharedKey, "a rejected key must not be retried")
        XCTAssertEqual(manager.state.pairingCode, "1155", "the code is what lets us recover unattended")
    }

    func testAuthenticationFailureIsRecordedAndClearedByAReading() {
        let manager = makeManager(state: pairedState(pairingCode: "1155", peripheralIdentifier: UUID(), sharedKey: Data(repeating: 0x66, count: 16)))

        manager.sensor(manager.sensor, didError: G7AuthenticatorError.rejected(authStatus: 2, failureCode: .deviceTypeRestriction))
        XCTAssertNotNil(manager.state.lastAuthenticationFailure)
        XCTAssertNotNil(manager.state.lastAuthenticationFailureDate)
        XCTAssertEqual(manager.lifecycleState, .connecting, "paired but no reading yet")

        // Timeouts happen on flaky links and are not worth alarming over.
        let cleared = makeManager(state: pairedState(pairingCode: "1155", peripheralIdentifier: UUID(), sharedKey: nil))
        cleared.sensor(cleared.sensor, didError: G7AuthenticatorError.timeout(step: "challenge"))
        XCTAssertNil(cleared.state.lastAuthenticationFailure)

        // A successful handshake clears the record.
        manager.sensor(manager.sensor, didAuthenticateWith: Data(repeating: 0x77, count: 16), deviceName: nil)
        XCTAssertNil(manager.state.lastAuthenticationFailure)
    }

    func testFailureFieldsRoundTrip() {
        var state = G7CGMManagerState()
        state.lastAuthenticationFailure = "refused"
        state.lastAuthenticationFailureDate = Date(timeIntervalSince1970: 1_700_000_000)
        let restored = G7CGMManagerState(rawValue: state.rawValue)
        XCTAssertEqual(restored.lastAuthenticationFailure, "refused")
        XCTAssertEqual(restored.lastAuthenticationFailureDate, state.lastAuthenticationFailureDate)
    }

    func testAnUnpairedDirectManagerWaitsForPairing() {
        var state = G7CGMManagerState()
        state.sessionMode = .direct
        let manager = makeManager(state: state)
        XCTAssertEqual(manager.lifecycleState, .unpaired)
        XCTAssertFalse(manager.cgmManagerStatus.hasValidSensorSession)

        manager.applyPairingResult(pairingCode: "0420", peripheralIdentifier: UUID(), sharedKey: Data(repeating: 1, count: 16), sensorName: "DXCM99")
        XCTAssertEqual(manager.lifecycleState, .connecting)
        XCTAssertTrue(manager.cgmManagerStatus.hasValidSensorSession)
        XCTAssertNil(manager.state.previousSensor, "there was no sensor before")
    }

    func testLegacySessionIsSearchingNotConnecting() {
        var state = G7CGMManagerState(rawValue: legacyRawState)
        state.sensorID = nil
        XCTAssertEqual(makeManager(state: state).lifecycleState, .searching)
    }

    /// The sensor advertises as "DXCMxx" but reports "Dexcomxx" once
    /// connected, and a reconnect retrieves it under the latter name. In the
    /// field, whole-name comparison made every reconnect after the first
    /// fail silently.
    func testSensorIdentityIgnoresTheNameChange() {
        let id = UUID()
        let paired = G7SensorCredentials(sensorID: "DXCMka", pairingCode: "1155", sharedKey: nil, peripheralIdentifier: id)
        XCTAssertTrue(G7Sensor.isSensor(identifier: id, name: "Dexcomka", describedBy: paired))
        XCTAssertTrue(G7Sensor.isSensor(identifier: id, name: nil, describedBy: paired))
        XCTAssertFalse(G7Sensor.isSensor(identifier: UUID(), name: "DXCMka", describedBy: paired), "a different peripheral with the same name is not ours")

        let byNameOnly = G7SensorCredentials(sensorID: "DXCMka", pairingCode: nil, sharedKey: nil, peripheralIdentifier: nil)
        XCTAssertTrue(G7Sensor.isSensor(identifier: UUID(), name: "Dexcomka", describedBy: byNameOnly))
        XCTAssertTrue(G7Sensor.isSensor(identifier: UUID(), name: "DXCMka", describedBy: byNameOnly))
        XCTAssertFalse(G7Sensor.isSensor(identifier: UUID(), name: "DXCMzz", describedBy: byNameOnly))
        XCTAssertFalse(G7Sensor.isSensor(identifier: UUID(), name: nil, describedBy: byNameOnly))

        XCTAssertFalse(G7Sensor.isSensor(identifier: UUID(), name: "DXCMka", describedBy: G7SensorCredentials()), "nothing known means nothing matches")
    }

    func testSensorNameFamilies() {
        XCTAssertTrue(G7Sensor.isSensorName("DXCMka"))
        XCTAssertTrue(G7Sensor.isSensorName("DX02ka"))
        XCTAssertTrue(G7Sensor.isSensorName("Dexcomka"))
        XCTAssertTrue(G7Sensor.isSensorName("DX01ka"), "Stelo")
        XCTAssertFalse(G7Sensor.isSensorName("Omnipod"))
    }

    func testModelNameCarriesTheNominalSessionLength() {
        let tenDay = ExtendedVersionMessage(data: Data(hexadecimalString: "5200c0d70d00540600020404ff0c00")!)!
        let fifteenDay = ExtendedVersionMessage(data: Data(hexadecimalString: "5200406f1400880e00010a04ff1100")!)!
        XCTAssertEqual(G7SensorModel.g7.displayName(sessionLength: tenDay.sessionLength), "Dexcom G7 10 Day")
        XCTAssertEqual(G7SensorModel.g7.displayName(sessionLength: fifteenDay.sessionLength), "Dexcom G7 15 Day")
        XCTAssertEqual(G7SensorModel.stelo.displayName(sessionLength: fifteenDay.sessionLength), "Dexcom Stelo 15 Day")
        XCTAssertEqual(G7SensorModel.g7.displayName(sessionLength: nil), "Dexcom G7", "nothing reported yet")
    }

    func testSensorModelFromAdvertisedName() {
        XCTAssertEqual(G7SensorModel(advertisedName: "DXCMka"), .g7)
        XCTAssertEqual(G7SensorModel(advertisedName: "DX02ka"), .onePlus)
        XCTAssertEqual(G7SensorModel(advertisedName: "DX01ka"), .stelo)
        XCTAssertNil(G7SensorModel(advertisedName: "Dexcomka"), "the connected-form name does not say which model")
        XCTAssertNil(G7SensorModel(advertisedName: "Omnipod"))

        var state = G7CGMManagerState()
        state.sensorID = "DX01ka"
        let manager = makeManager(state: state)
        XCTAssertEqual(manager.sensorModel, .stelo)
        XCTAssertEqual(manager.localizedTitle, "Dexcom Stelo")
        XCTAssertEqual(makeManager(state: G7CGMManagerState()).sensorModel, .g7, "G7 until a sensor is known")
    }

    func testAuthVerdictFailureCodes() {
        XCTAssertEqual(AuthChallengeRxMessage(data: Data([0x05, 0x02, 0x03]))?.failureCode, .noAppKey)
        XCTAssertEqual(AuthChallengeRxMessage(data: Data([0x05, 0x02, 0x02]))?.failureCode, .deviceTypeRestriction)
        XCTAssertEqual(AuthChallengeRxMessage(data: Data([0x05, 0x02, 0x01]))?.failureCode, .challengeMismatch)
        XCTAssertNil(AuthChallengeRxMessage(data: Data([0x05, 0x02, 0x7f]))?.failureCode, "unknown byte, no name")
        // On success byte 2 is the bond state, not a failure code.
        let bonded = AuthChallengeRxMessage(data: Data([0x05, 0x01, 0x01]))
        XCTAssertNil(bonded?.failureCode)
        XCTAssertTrue(bonded?.isAuthenticated ?? false)
        XCTAssertTrue(bonded?.isBonded ?? false)
    }

    /// `noAppKey` is the sensor saying it has no key for us; the session
    /// recovers unattended by pairing again with the retained code, so it is
    /// not something to alarm the user about.
    func testNoAppKeyIsNotRecordedAsARefusal() {
        let manager = makeManager(state: pairedState(pairingCode: "1155", peripheralIdentifier: UUID(), sharedKey: Data(repeating: 0x66, count: 16)))
        manager.sensor(manager.sensor, didError: G7AuthenticatorError.rejected(authStatus: 2, failureCode: .noAppKey))
        XCTAssertNil(manager.state.lastAuthenticationFailure)

        manager.sensor(manager.sensor, didError: G7AuthenticatorError.rejected(authStatus: 2, failureCode: .deviceTypeRestriction))
        XCTAssertNotNil(manager.state.lastAuthenticationFailure)
    }

    func testForgettingASensorClosesItsSessionOnce() {
        var state = G7CGMManagerState(rawValue: legacyRawState)
        state.sensorID = "DXCM99"
        let manager = makeManager(state: state)

        manager.scanForNewSensor()
        XCTAssertNil(manager.state.sensorID)
        XCTAssertNil(manager.state.sensorEndRecordedFor, "bookkeeping resets with the identity")

        // A second forget with no sensor known records nothing.
        manager.scanForNewSensor()
        XCTAssertNil(manager.state.sensorEndRecordedFor)
    }

    func testNewerFirmwareFailureStatesCountAsFailed() {
        for raw: UInt8 in [27, 28, 29] {
            XCTAssertTrue(AlgorithmState(rawValue: raw).sensorFailed, "state \(raw)")
        }
        XCTAssertFalse(AlgorithmState(rawValue: 1).sensorFailed, "stopped is the pre-start state, not a failure")
    }

    /// The official apps draw no arrow above 8 mg/dL/min; a triple arrow
    /// there overstated a rate the sensor itself flags as out of range.
    func testTrendArrowIsDroppedBeyondTheOfficialLimit() {
        // Sample from G7GlucoseMessageTests with the trend byte (offset 15) replaced.
        func message(trendTenths: Int8) -> G7GlucoseMessage {
            var data = Data(hexadecimalString: "4e00c35501002601000106008a00060187000f")!
            data[15] = UInt8(bitPattern: trendTenths)
            return G7GlucoseMessage(data: data)!
        }
        XCTAssertEqual(message(trendTenths: 35).trendType, .upUpUp)
        XCTAssertEqual(message(trendTenths: -35).trendType, .downDownDown)
        XCTAssertEqual(message(trendTenths: 80).trendType, .upUpUp, "8.0 is the last rate with an arrow")
        XCTAssertNil(message(trendTenths: 81).trendType)
        XCTAssertNil(message(trendTenths: -90).trendType)
    }

    func testSensorRecordRoundTrips() {
        let record = G7SensorRecord(
            sensorID: "DXCMka", pairingCode: "1155", serialNumber: "771958849216", firmwareVersion: "44.192.105.72",
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000), activatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            sessionLength: 1_339_200, warmupDuration: 3_720,
            endedAt: Date(timeIntervalSince1970: 1_701_000_000), endReason: .replaced,
            failureMessage: "known(sensorFailed)", failedAt: Date(timeIntervalSince1970: 1_700_900_000)
        )
        XCTAssertEqual(G7SensorRecord(rawValue: record.rawValue), record)
        XCTAssertEqual(record.model, .g7)
        XCTAssertTrue(PropertyListSerialization.propertyList(record.rawValue, isValidFor: .binary))
        XCTAssertNil(G7SensorRecord(rawValue: ["sensorID": "x"]), "an end date and reason are required")
    }

    /// Replacing a sensor keeps the old one, with how and when it ended;
    /// a failure seen while it was current rides along.
    func testReplacingASensorKeepsItAsPrevious() {
        var state = G7CGMManagerState(rawValue: legacyRawState)
        state.pairedAt = Date(timeIntervalSinceNow: -60_000)
        state.pairingCode = "1155"
        state.sensorFailureMessage = "known(sensorFailed)"
        state.sensorFailedAt = Date(timeIntervalSinceNow: -600)
        let manager = makeManager(state: state)

        manager.applyPairingResult(pairingCode: "0420", peripheralIdentifier: UUID(), sharedKey: Data(repeating: 1, count: 16))

        let previous = manager.state.previousSensor
        XCTAssertEqual(previous?.sensorID, "DXCM99")
        XCTAssertEqual(previous?.pairingCode, "1155")
        XCTAssertEqual(previous?.endReason, .replaced)
        XCTAssertEqual(previous?.failureMessage, "known(sensorFailed)")
        XCTAssertNotNil(previous?.failedAt)
        XCTAssertEqual(previous?.pairedAt, state.pairedAt)

        // The new sensor starts clean, with its own pairing date.
        XCTAssertNil(manager.state.sensorFailureMessage)
        XCTAssertNotNil(manager.state.pairedAt)
        XCTAssertGreaterThan(manager.state.pairedAt!, state.pairedAt!)
    }

    func testDeletingKeepsThePreviousSensorAsRemoved() {
        var state = G7CGMManagerState(rawValue: legacyRawState)
        state.sensorID = "DXCM99"
        let manager = makeManager(state: state)
        let done = expectation(description: "deleted")
        manager.delete { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(manager.state.previousSensor?.endReason, .deleted)
    }

    func testAuthenticationPersistsTheDerivedKey() {
        let manager = makeManager(state: pairedState(pairingCode: "1155", peripheralIdentifier: UUID(), sharedKey: nil))
        let key = Data(repeating: 0x55, count: 16)

        manager.sensor(manager.sensor, didAuthenticateWith: key, deviceName: "Dexcom99")

        XCTAssertEqual(manager.state.sharedKey, key)
    }
}

private final class BackfillRecordingDelegate: G7SensorDelegate {
    let backfillArrived = XCTestExpectation(description: "backfill delivered")
    var backfill: [G7BackfillMessage] = []

    func sensorDidConnect(_ sensor: G7Sensor, name: String) {}
    func sensorDisconnected(_ sensor: G7Sensor, suspectedEndOfSession: Bool) {}
    func sensor(_ sensor: G7Sensor, didError error: Error) {}
    func sensor(_ sensor: G7Sensor, logComms comms: String) {}
    func sensor(_ sensor: G7Sensor, log message: String, type: DeviceLogEntryType) {}
    func sensor(_ sensor: G7Sensor, didRead glucose: G7GlucoseMessage) {}
    func sensor(_ sensor: G7Sensor, didReadBackfill backfill: [G7BackfillMessage]) {
        self.backfill = backfill
        backfillArrived.fulfill()
    }
    func sensor(_ sensor: G7Sensor, didDiscoverNewSensor name: String, activatedAt: Date) -> Bool { false }
    func sensor(_ sensor: G7Sensor, didReceive extendedVersion: ExtendedVersionMessage) {}
    func sensor(_ sensor: G7Sensor, didReceive transmitterVersion: TransmitterVersionMessage) {}
    func sensor(_ sensor: G7Sensor, didReceiveCalibrationResponse response: G7CalibrateRxMessage) {}
    func sensor(_ sensor: G7Sensor, didReadCalibrationBounds bounds: G7CalibrationBoundsMessage) {}
    func sensorConnectionStatusDidUpdate(_ sensor: G7Sensor) {}
    func sensor(_ sensor: G7Sensor, didAuthenticateWith sharedKey: Data, deviceName: String?) {}
    func sensorDidInvalidateSharedKey(_ sensor: G7Sensor) {}
}
