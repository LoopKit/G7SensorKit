//
//  G7LifecycleAlertTests.swift
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

/// Records what the manager asks Loop to do with alerts. Main-actor bound,
/// like the issuing calls themselves.
@MainActor
private final class RecordingDelegate: CGMManagerDelegate {
    var issued: [Alert] = []
    var retracted: [Alert.Identifier] = []
    /// Ordered record of what happened, for ordering assertions.
    var events: [String] = []

    func issueAlert(_ alert: Alert) async {
        issued.append(alert)
        events.append("issue:" + alert.identifier.alertIdentifier)
    }

    func retractAlert(identifier: Alert.Identifier) async {
        retracted.append(identifier)
        events.append("retract:" + identifier.alertIdentifier)
    }

    func cgmManagerWantsDeletion(_ manager: CGMManager) async {
        events.append("delete")
    }

    nonisolated func doesIssuedAlertExist(identifier: Alert.Identifier) async throws -> Bool { false }
    nonisolated func lookupAllUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    nonisolated func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] { [] }
    nonisolated func recordRetractedAlert(_ alert: Alert, at date: Date) async throws {}
    nonisolated func deviceManager(_ manager: DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {}
    nonisolated func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {}
    nonisolated func startDateToFilterNewData(for manager: CGMManager) -> Date? { nil }
    nonisolated func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) {}
    nonisolated func cgmManager(_ manager: CGMManager, hasNew events: [PersistedCgmEvent]) {}
    nonisolated func cgmManagerDidUpdateState(_ manager: CGMManager) {}
    nonisolated func credentialStoragePrefix(for manager: CGMManager) -> String { "test" }
}

class G7LifecycleAlertScheduleTests: XCTestCase {

    private let day = TimeInterval(hours: 24)

    func testFreshSensorSchedulesEverything() {
        let now = Date()
        let expires = now.addingTimeInterval(10 * day)
        let ends = expires.addingTimeInterval(12 * 3600)
        let delays = G7LifecycleAlertSchedule.delays(sensorExpiresAt: expires, sensorEndsAt: ends, now: now)

        XCTAssertEqual(delays[.sensorExpiringSoon] ?? -1, 9 * day, accuracy: 1)
        XCTAssertEqual(delays[.sensorExpiringImminently] ?? -1, 10 * day - 2 * 3600, accuracy: 1)
        XCTAssertEqual(delays[.sensorExpired] ?? -1, 10 * day, accuracy: 1)
        XCTAssertEqual(delays[.sessionEnded] ?? -1, 10 * day + 12 * 3600, accuracy: 1)
    }

    /// Adopting a sensor that is already most of the way through its
    /// session must not fire warnings for moments that have passed.
    func testPastMomentsAreSkipped() {
        let now = Date()
        let expires = now.addingTimeInterval(3600) // an hour left
        let ends = expires.addingTimeInterval(12 * 3600)
        let delays = G7LifecycleAlertSchedule.delays(sensorExpiresAt: expires, sensorEndsAt: ends, now: now)

        XCTAssertNil(delays[.sensorExpiringSoon])
        XCTAssertNil(delays[.sensorExpiringImminently])
        XCTAssertEqual(delays[.sensorExpired] ?? -1, 3600, accuracy: 1)
        XCTAssertNotNil(delays[.sessionEnded])
    }

    func testEverySessionTimedAlertHasAScheduleEntry() {
        let now = Date()
        let delays = G7LifecycleAlertSchedule.delays(
            sensorExpiresAt: now.addingTimeInterval(10 * day),
            sensorEndsAt: now.addingTimeInterval(10.5 * day),
            now: now
        )
        XCTAssertEqual(Set(delays.keys), Set(G7LifecycleAlert.sessionTimed))
    }

    func testAlertContentIsComplete() {
        for alert in G7LifecycleAlert.allCases {
            let loopAlert = alert.alert(managerIdentifier: "G7CGMManager")
            XCTAssertEqual(loopAlert.identifier.alertIdentifier, alert.rawValue)
            XCTAssertFalse(loopAlert.foregroundContent?.title.isEmpty ?? true)
            XCTAssertFalse(loopAlert.foregroundContent?.body.isEmpty ?? true)
        }
        XCTAssertEqual(G7LifecycleAlert.sensorFailed.interruptionLevel, .critical)
    }
}

@MainActor
class G7LifecycleAlertManagerTests: XCTestCase {

    private var recorder: RecordingDelegate!

    private func makeManager(state: G7CGMManagerState = G7CGMManagerState()) -> G7CGMManager {
        let sensor = G7Sensor(mode: state.sessionMode, credentials: state.sensorCredentials, bluetoothManager: TestBluetoothManager())
        let manager = G7CGMManager(state: state, sensor: sensor)
        recorder = RecordingDelegate()
        manager.cgmManagerDelegate = recorder
        manager.delegateQueue = DispatchQueue.main
        return manager
    }

    /// Delegate calls are dispatched; give them a moment to land.
    private func settle() {
        let expectation = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    private var okReading: G7GlucoseMessage {
        G7GlucoseMessage(data: Data(hexadecimalString: "4e00c35501002601000106008a00060187000f")!)!
    }

    func testDiscoveringASensorSchedulesTheSessionTimedAlerts() {
        let manager = makeManager()
        _ = manager.sensor(manager.sensor, didDiscoverNewSensor: "DXCM99", activatedAt: Date())
        settle()

        let scheduled = recorder.issued.filter { alert in
            if case .delayed = alert.trigger { return true }
            return false
        }
        XCTAssertEqual(
            Set(scheduled.map(\.identifier.alertIdentifier)),
            Set(G7LifecycleAlert.sessionTimed.map(\.rawValue))
        )
        XCTAssertNotNil(manager.state.lifecycleAlertsScheduledFor)
    }

    func testReschedulingIsIdempotentPerSensorAndLifetime() {
        let manager = makeManager()
        _ = manager.sensor(manager.sensor, didDiscoverNewSensor: "DXCM99", activatedAt: Date())
        settle()
        let issuedOnce = recorder.issued.count

        // Same sensor, same lifetime: a relaunch-style repeat must not
        // duplicate notifications Loop already holds.
        _ = manager.sensor(manager.sensor, didDiscoverNewSensor: "DXCM99", activatedAt: manager.state.activatedAt!)
        settle()
        XCTAssertEqual(recorder.issued.count, issuedOnce)

        // A 15-day sensor reports a longer session: the alerts move.
        let fifteenDay = ExtendedVersionMessage(data: Data(hexadecimalString: "5200406f1400880e00010a04ff1100")!)!
        manager.sensor(manager.sensor, didReceive: fifteenDay)
        settle()
        XCTAssertGreaterThan(recorder.issued.count, issuedOnce)
        XCTAssertTrue(recorder.retracted.contains { $0.alertIdentifier == G7LifecycleAlert.sensorExpired.rawValue })
    }

    func testReadingsRearmSignalLoss() {
        var state = G7CGMManagerState()
        state.sensorID = "DXCM99"
        state.activatedAt = Date(timeIntervalSinceNow: -3600)
        let manager = makeManager(state: state)

        manager.sensor(manager.sensor, didRead: okReading)
        settle()

        let signalLoss = recorder.issued.filter { $0.identifier.alertIdentifier == G7LifecycleAlert.signalLoss.rawValue }
        XCTAssertEqual(signalLoss.count, 1)
        guard case .delayed(let interval) = signalLoss[0].trigger else {
            return XCTFail("signal loss must be scheduled ahead, not raised now")
        }
        XCTAssertEqual(interval, G7LifecycleAlert.signalLossInterval)
        XCTAssertTrue(recorder.retracted.contains { $0.alertIdentifier == G7LifecycleAlert.signalLoss.rawValue }, "the previous arming is cleared first")
    }

    func testRefusalRaisesOnceAndClearsOnReading() {
        var state = G7CGMManagerState()
        state.sessionMode = .direct
        state.sensorID = "DXCM99"
        state.activatedAt = Date(timeIntervalSinceNow: -3600)
        state.pairingCode = "1155"
        let manager = makeManager(state: state)

        manager.sensor(manager.sensor, didError: G7AuthenticatorError.rejected(authStatus: 2, failureCode: .deviceTypeRestriction))
        manager.sensor(manager.sensor, didError: G7AuthenticatorError.rejected(authStatus: 2, failureCode: .deviceTypeRestriction))
        settle()
        XCTAssertEqual(recorder.issued.filter { $0.identifier.alertIdentifier == G7LifecycleAlert.connectionRefused.rawValue }.count, 1)

        manager.sensor(manager.sensor, didRead: okReading)
        settle()
        XCTAssertTrue(recorder.retracted.contains { $0.alertIdentifier == G7LifecycleAlert.connectionRefused.rawValue })
    }

    /// LibreLoop #13: alerts left standing when the CGM is deleted are
    /// replayed by Loop at every launch until acknowledged. Deleting must
    /// retract every alert this manager can issue, and must do so before the
    /// deletion notification that makes Loop release the manager.
    func testDeletingTheCGMRetractsEveryAlertBeforeNotifying() {
        var state = G7CGMManagerState()
        state.sensorID = "DXCM99"
        state.activatedAt = Date()
        state.lifecycleAlertsScheduledFor = "scheduled"
        let manager = makeManager(state: state)

        let done = expectation(description: "delete completed")
        manager.delete { done.fulfill() }
        wait(for: [done], timeout: 2)
        settle()

        XCTAssertEqual(
            Set(recorder.retracted.map(\.alertIdentifier)),
            Set(G7LifecycleAlert.allCases.map(\.rawValue)),
            "every alert the manager can issue must be retracted"
        )
        let deleteIndex = recorder.events.firstIndex(of: "delete")
        XCTAssertNotNil(deleteIndex)
        for (index, event) in recorder.events.enumerated() where event.hasPrefix("retract:") {
            XCTAssertLessThan(index, deleteIndex ?? -1, "\(event) must land before Loop is told to delete")
        }
    }

    func testForgettingTheSensorRetractsEverything() {
        var state = G7CGMManagerState()
        state.sensorID = "DXCM99"
        state.activatedAt = Date()
        state.lifecycleAlertsScheduledFor = "stale"
        let manager = makeManager(state: state)

        manager.scanForNewSensor()
        settle()

        XCTAssertEqual(
            Set(recorder.retracted.map(\.alertIdentifier)),
            Set(G7LifecycleAlert.allCases.map(\.rawValue))
        )
        XCTAssertNil(manager.state.lifecycleAlertsScheduledFor)
    }
}
