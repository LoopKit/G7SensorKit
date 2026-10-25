//
//  G7CalibrationTests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import CoreBluetooth
import LoopKit
@testable import G7SensorKit

private class TestBluetoothManager: G7BluetoothManager {
    override func makeCentralManager(queue: DispatchQueue) -> CBCentralManager {
        return CBCentralManager(delegate: self, queue: queue)
    }
}

/// Records the reading results the manager hands Loop.
@MainActor
private final class ReadingRecordingDelegate: CGMManagerDelegate {
    nonisolated(unsafe) var readingResults: [CGMReadingResult] = []

    nonisolated func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) {
        readingResults.append(readingResult)
    }

    func issueAlert(_ alert: Alert) async {}
    func retractAlert(identifier: Alert.Identifier) async {}
    func cgmManagerWantsDeletion(_ manager: CGMManager) async {}
    nonisolated func doesIssuedAlertExist(identifier: Alert.Identifier) async throws -> Bool { false }
    nonisolated func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    nonisolated func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    nonisolated func recordRetractedAlert(_ alert: Alert, at date: Date) async throws {}
    nonisolated func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {}
    nonisolated func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {}
    nonisolated func startDateToFilterNewData(for manager: CGMManager) -> Date? { nil }
    nonisolated func cgmManager(_ manager: CGMManager, hasNew events: [PersistedCgmEvent]) {}
    nonisolated func cgmManagerDidUpdateState(_ manager: CGMManager) {}
    nonisolated func credentialStoragePrefix(for manager: CGMManager) -> String { "test" }
}

final class G7CalibrationTests: XCTestCase {

    func testCalibrateRequestLayout() {
        let request = G7CalibrateTxMessage(glucose: 120, sensorAge: 0x00010203)
        XCTAssertEqual(request.data.hexadecimalString, "34" + "7800" + "03020100")
    }

    func testCalibrateReplyStatus() {
        // Observed on a sensor 2026-09-15 for an accepted 145 mg/dL.
        let acceptedLow = G7CalibrateRxMessage(data: Data(hexadecimalString: "34000100")!)!
        XCTAssertTrue(acceptedLow.accepted)
        XCTAssertNil(G7CalibrationRefusal(status: acceptedLow.status))
        XCTAssertEqual(G7CalibrateRxMessage(data: Data(hexadecimalString: "34000000")!)?.accepted, true)

        let acceptanceError = G7CalibrateRxMessage(data: Data(hexadecimalString: "34000101")!)!
        XCTAssertFalse(acceptanceError.accepted)
        XCTAssertEqual(G7CalibrationRefusal(status: acceptanceError.status), .acceptanceError(1))

        let outlier = G7CalibrateRxMessage(data: Data(hexadecimalString: "3400020a")!)!
        XCTAssertFalse(outlier.accepted)
        XCTAssertEqual(outlier.result, 2)
        XCTAssertEqual(outlier.detail, 10)
        XCTAssertEqual(G7CalibrationRefusal(status: outlier.status), .extremeOutlier)
        XCTAssertEqual(G7CalibrationRefusal(status: G7CalibrateRxMessage(data: Data(hexadecimalString: "34000208")!)!.status), .notPermitted)
        XCTAssertEqual(G7CalibrationRefusal(status: G7CalibrateRxMessage(data: Data(hexadecimalString: "3400020c")!)!.status), .unknown(result: 2, detail: 12))
        XCTAssertEqual(G7CalibrationRefusal(status: G7CalibrateRxMessage(data: Data(hexadecimalString: "34000300")!)!.status), .factoryCalibrated)
        XCTAssertEqual(G7CalibrationRefusal(status: G7CalibrateRxMessage(data: Data(hexadecimalString: "34000500")!)!.status), .unknown(result: 5, detail: 0))

        XCTAssertNil(G7CalibrateRxMessage(data: Data(hexadecimalString: "3400")!))
        XCTAssertNil(G7CalibrateRxMessage(data: Data(hexadecimalString: "4e000100")!))
    }

    func testCalibrationBoundsLayout() {
        // 32 | status 00 | session 03 | signature 78563412 | lastGlucose 7a00 (122) |
        // lastCalibrationTime 1ec0 0000 (49182) | processing 02 | permitted 01 |
        // display 04 | lastProcessingUpdate 2ac1 0000 (49450)
        let data = Data(hexadecimalString: "32" + "00" + "03" + "12345678" + "7a00" + "1ec00000" + "02" + "01" + "04" + "2ac10000")!
        XCTAssertEqual(data.count, 20)
        let bounds = G7CalibrationBoundsMessage(data: data)!
        XCTAssertEqual(bounds.sessionNumber, 3)
        XCTAssertEqual(bounds.sessionSignature, 0x78563412)
        XCTAssertEqual(bounds.lastGlucose, 122)
        XCTAssertEqual(bounds.lastCalibrationTime, 49182)
        XCTAssertEqual(bounds.processingStatus, .inProgress)
        XCTAssertTrue(bounds.calibrationsPermitted)
        XCTAssertEqual(bounds.lastDisplayType, .receiver)
        XCTAssertEqual(bounds.lastProcessingUpdateTime, 49450)
        XCTAssertTrue(bounds.hasCalibration)

        let factory = G7CalibrationBoundsMessage(data: Data(hexadecimalString: "3200030000000000000000000001000000000000")!)!
        XCTAssertFalse(factory.hasCalibration)
        XCTAssertEqual(factory.processingStatus, .factoryCalibrated)
        XCTAssertNil(G7CalibrationBoundsMessage(data: Data(hexadecimalString: "3200")!))
    }

    func testRecordRoundTrips() {
        let accepted = G7CalibrationRecord(glucose: 118, enteredAt: Date(timeIntervalSince1970: 1_700_000_000), outcome: .accepted(at: Date(timeIntervalSince1970: 1_700_000_100)), processingStatus: .completeHigh)
        XCTAssertEqual(G7CalibrationRecord(rawValue: accepted.rawValue), accepted)
        let rejected = G7CalibrationRecord(glucose: 118, enteredAt: Date(), outcome: .rejected(status: 5, at: Date()))
        XCTAssertEqual(G7CalibrationRecord(rawValue: rejected.rawValue), rejected)
        let pending = G7CalibrationRecord(glucose: 118, enteredAt: Date())
        XCTAssertEqual(G7CalibrationRecord(rawValue: pending.rawValue), pending)
        let expired = G7CalibrationRecord(glucose: 118, enteredAt: Date(), outcome: .expired(at: Date()))
        XCTAssertEqual(G7CalibrationRecord(rawValue: expired.rawValue), expired)
        XCTAssertTrue(NSDictionary(dictionary: accepted.rawValue).isEqual(to: G7CalibrationRecord(rawValue: accepted.rawValue)!.rawValue))
    }

    func testSensorQueuesACalibrationUntilTheNextConnection() {
        let sensor = G7Sensor(mode: .direct, credentials: G7SensorCredentials(sensorID: "DXCM99", pairingCode: "0420", sharedKey: nil, peripheralIdentifier: nil), bluetoothManager: TestBluetoothManager())
        XCTAssertNil(sensor.queuedCalibration)
        sensor.calibrate(glucose: 110, at: Date())
        sensor.calibrate(glucose: 112, at: Date())
        XCTAssertEqual(sensor.queuedCalibration?.glucose, 112, "the newest calibration replaces the one still waiting")
        sensor.cancelPendingCalibration()
        XCTAssertNil(sensor.queuedCalibration)
    }

    func testManagerTracksTheCalibrationOutcome() {
        var state = G7CGMManagerState()
        state.sessionMode = .direct
        state.sensorID = "DXCM99"
        state.pairingCode = "0420"
        let sensor = G7Sensor(mode: .direct, credentials: state.sensorCredentials, bluetoothManager: TestBluetoothManager())
        let manager = G7CGMManager(state: state, sensor: sensor)

        manager.calibrate(glucose: 105)
        XCTAssertEqual(manager.calibration?.glucose, 105)
        XCTAssertEqual(manager.calibration?.outcome, .pending)
        XCTAssertTrue(manager.hasPendingCalibration)

        manager.sensor(sensor, didReceiveCalibrationResponse: G7CalibrateRxMessage(data: Data(hexadecimalString: "34000100")!)!)
        guard case .accepted? = manager.calibration?.outcome else {
            return XCTFail("expected the calibration to be accepted")
        }

        let inProgress = G7CalibrationBoundsMessage(data: Data(hexadecimalString: "32" + "00" + "03" + "12345678" + "7a00" + "1ec00000" + "02" + "01" + "04" + "2ac10000")!)!
        manager.sensor(sensor, didReadCalibrationBounds: inProgress)
        XCTAssertEqual(manager.calibration?.processingStatus, .inProgress)
        XCTAssertEqual(manager.state.calibrationBounds, inProgress)

        // Persisted, and a pending one is owed to the sensor again after a relaunch.
        var restored = G7CGMManagerState(rawValue: manager.rawState)
        XCTAssertEqual(restored.calibration, manager.calibration)
        restored.calibration = G7CalibrationRecord(glucose: 99, enteredAt: Date())
        let relaunched = G7CGMManager(state: restored, sensor: G7Sensor(mode: .direct, credentials: restored.sensorCredentials, bluetoothManager: TestBluetoothManager()))
        XCTAssertEqual(relaunched.sensor.queuedCalibration?.glucose, 99)

        manager.cancelPendingCalibration()
        XCTAssertNotNil(manager.calibration, "an answered calibration is not a pending one; cancelling leaves it")
    }

    func testManagerMarksAStaleCalibrationExpired() {
        var state = G7CGMManagerState()
        state.sessionMode = .direct
        let sensor = G7Sensor(mode: .direct, credentials: state.sensorCredentials, bluetoothManager: TestBluetoothManager())
        let manager = G7CGMManager(state: state, sensor: sensor)
        let enteredAt = Date().addingTimeInterval(-G7Sensor.calibrationMaxAge - 60)
        manager.calibrate(glucose: 105, at: enteredAt)

        manager.sensor(sensor, didDiscardStaleCalibrationEnteredAt: enteredAt.addingTimeInterval(-1))
        XCTAssertEqual(manager.calibration?.outcome, .pending, "only the calibration that was dropped is expired")

        manager.sensor(sensor, didDiscardStaleCalibrationEnteredAt: enteredAt)
        guard case .expired? = manager.calibration?.outcome else {
            return XCTFail("expected the calibration to be expired")
        }
    }

    /// The entered meter value is emitted as a user-entered sample at the
    /// time it was taken.
    @MainActor
    func testCalibrateEmitsTheEnteredMeterValueAsAUserEnteredSample() {
        var state = G7CGMManagerState()
        state.sessionMode = .direct
        state.sensorID = "DXCM99"
        let sensor = G7Sensor(mode: .direct, credentials: state.sensorCredentials, bluetoothManager: TestBluetoothManager())
        let manager = G7CGMManager(state: state, sensor: sensor)
        let recorder = ReadingRecordingDelegate()
        manager.cgmManagerDelegate = recorder
        manager.delegateQueue = DispatchQueue.main

        let enteredAt = Date(timeIntervalSince1970: 1_700_000_000)
        manager.calibrate(glucose: 145, at: enteredAt)

        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        guard case .newData(let samples)? = recorder.readingResults.last, samples.count == 1 else {
            return XCTFail("expected one emitted sample, got \(recorder.readingResults)")
        }
        let sample = samples[0]
        XCTAssertEqual(sample.quantity.doubleValue(for: .milligramsPerDeciliter), 145)
        XCTAssertEqual(sample.date, enteredAt)
        XCTAssertTrue(sample.wasUserEntered)
        XCTAssertFalse(sample.isDisplayOnly)
        XCTAssertNil(sample.trend)
        XCTAssertNil(sample.trendRate)
        XCTAssertNotEqual(sample.syncIdentifier, "invalid")
    }

    /// A reading the sensor shifted for display is still a device reading:
    /// display-only, never user-entered.
    @MainActor
    func testDisplayOnlyReadingIsNotUserEntered() {
        var state = G7CGMManagerState()
        state.sessionMode = .direct
        state.sensorID = "DXCM99"
        let sensor = G7Sensor(mode: .direct, credentials: state.sensorCredentials, bluetoothManager: TestBluetoothManager())
        let manager = G7CGMManager(state: state, sensor: sensor)
        let recorder = ReadingRecordingDelegate()
        manager.cgmManagerDelegate = recorder
        manager.delegateQueue = DispatchQueue.main
        sensor.activationDate = Date(timeIntervalSince1970: 1_700_000_000)

        // Byte 18 = 0x1f (bgTriggered), as the sensor sends after a calibration.
        let displayOnly = G7GlucoseMessage(data: Data(hexadecimalString: "4e00c6cc0d00ca0b00010500610006fe5b001f")!)!
        XCTAssertTrue(displayOnly.glucoseIsDisplayOnly)
        manager.sensor(sensor, didRead: displayOnly)

        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        guard case .newData(let samples)? = recorder.readingResults.last, samples.count == 1 else {
            return XCTFail("expected one emitted sample, got \(recorder.readingResults)")
        }
        XCTAssertTrue(samples[0].isDisplayOnly)
        XCTAssertFalse(samples[0].wasUserEntered)
    }

    func testDisplayTypeSurvivesARelaunch() {
        var state = G7CGMManagerState()
        state.displayType = .watch
        XCTAssertEqual(G7CGMManagerState(rawValue: state.rawValue).displayType, .watch)
        XCTAssertEqual(G7CGMManagerState(rawValue: [:]).displayType, .phone, "state saved before this field defaults to the phone slot")
    }

    func testCalibrationIsForgottenWithTheSensor() {
        var state = G7CGMManagerState()
        state.sessionMode = .direct
        state.sensorID = "DXCM99"
        state.pairingCode = "0420"
        state.calibration = G7CalibrationRecord(glucose: 105, enteredAt: Date())
        let manager = G7CGMManager(state: state, sensor: G7Sensor(mode: .direct, credentials: state.sensorCredentials, bluetoothManager: TestBluetoothManager()))
        manager.applyPairingResult(pairingCode: "1234", peripheralIdentifier: UUID(), sharedKey: Data(repeating: 1, count: 16), sensorName: "DXCMzz")
        XCTAssertNil(manager.calibration)
    }
}
