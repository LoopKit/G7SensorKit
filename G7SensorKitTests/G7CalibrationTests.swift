//
//  G7CalibrationTests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import CoreBluetooth
@testable import G7SensorKit

private class TestBluetoothManager: G7BluetoothManager {
    override func makeCentralManager(queue: DispatchQueue) -> CBCentralManager {
        return CBCentralManager(delegate: self, queue: queue)
    }
}

final class G7CalibrationTests: XCTestCase {

    func testCalibrateRequestLayout() {
        let request = G7CalibrateTxMessage(glucose: 120, sensorAge: 0x00010203)
        XCTAssertEqual(request.data.hexadecimalString, "34" + "7800" + "03020100")
    }

    func testCalibrateReplyStatus() {
        XCTAssertEqual(G7CalibrateRxMessage(data: Data(hexadecimalString: "34000100")!)?.accepted, true)
        let refused = G7CalibrateRxMessage(data: Data(hexadecimalString: "34000500")!)
        XCTAssertEqual(refused?.accepted, false)
        XCTAssertEqual(refused?.status, 5)
        XCTAssertNil(G7CalibrateRxMessage(data: Data(hexadecimalString: "3400")!))
        XCTAssertNil(G7CalibrateRxMessage(data: Data(hexadecimalString: "4e000100")!))
    }

    func testCalibrationBoundsLayout() {
        // 32 | status 00 | session 03 | signature 78563412 | lastEGV 7a00 (122) |
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
        XCTAssertEqual(bounds.lastDisplayType, 4)
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
