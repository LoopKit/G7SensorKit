//
//  G7CGMManager.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 9/24/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopAlgorithm
import LoopKit
import os.log



public protocol G7StateObserver: AnyObject {
    func g7StateDidUpdate(_ state: G7CGMManagerState?)
    func g7ConnectionStatusDidChange()
}

public class G7CGMManager: CGMManager {
    public var inSignalLoss: Bool = false
    
    public var isInoperable: Bool {
        cgmManagerStatus.isInoperable
    }
    
    private let log = OSLog(category: "G7CGMManager")

    /// How long to wait for communication to resume after a suspected session end
    /// before forgetting the sensor and scanning for a new one. BLE handshake
    /// failures are indistinguishable from a stopped session at disconnect time;
    /// readings normally resume on the sensor's next 5-minute connection cycle.
    var suspectedSessionEndGracePeriod: TimeInterval = TimeInterval(minutes: 15)

    public var state: G7CGMManagerState {
        return lockedState.value
    }

    private func setState(_ changes: (_ state: inout G7CGMManagerState) -> Void) -> Void {
        return setStateWithResult(changes)
    }

    @discardableResult
    private func mutateState(_ changes: (_ state: inout G7CGMManagerState) -> Void) -> G7CGMManagerState {
        return setStateWithResult({ (state) -> G7CGMManagerState in
            changes(&state)
            return state
        })
    }

    private func setStateWithResult<ReturnType>(_ changes: (_ state: inout G7CGMManagerState) -> ReturnType) -> ReturnType {
        var oldValue: G7CGMManagerState!
        var returnType: ReturnType!
        let newValue = lockedState.mutate { (state) in
            oldValue = state
            returnType = changes(&state)
        }

        if oldValue != newValue {
            delegate.notify { delegate in
                delegate?.cgmManagerDidUpdateState(self)
                delegate?.cgmManager(self, didUpdate: self.cgmManagerStatus)
            }

            g7StateObservers.forEach { (observer) in
                observer.g7StateDidUpdate(newValue)
            }
        }

        return returnType
    }
    private let lockedState: Locked<G7CGMManagerState>

    private let g7StateObservers = WeakSynchronizedSet<G7StateObserver>()

    public weak var cgmManagerDelegate: CGMManagerDelegate? {
        get {
            return delegate.delegate
        }
        set {
            delegate.delegate = newValue
        }
    }

    public var delegateQueue: DispatchQueue! {
        get {
            return delegate.queue
        }
        set {
            delegate.queue = newValue
        }
    }

    private let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()

    public var providesBLEHeartbeat: Bool = true

    public var managedDataInterval: TimeInterval? {
        return .hours(3)
    }

    public var shouldSyncToRemoteService: Bool {
        return true
    }

    public var glucoseDisplay: GlucoseDisplayable? {
        return latestReading
    }

    public var isScanning: Bool {
        return sensor.isScanning
    }

    public var isConnected: Bool {
        return sensor.isConnected
    }

    public var sensorName: String? {
        return state.sensorID
    }

    public var sensorActivatedAt: Date? {
        return state.activatedAt
    }

    public var lifetime: TimeInterval {
        if let sessionLength = state.extendedVersion?.sessionLength {
            return sessionLength - G7Sensor.gracePeriod
        } else {
            return G7Sensor.defaultLifetime
        }
    }

    public var warmupDuration: TimeInterval {
        state.extendedVersion?.warmupDuration ?? G7Sensor.defaultWarmupDuration
    }

    public var sensorExpiresAt: Date? {
        guard let activatedAt = sensorActivatedAt else {
            return nil
        }
        return activatedAt.addingTimeInterval(lifetime)
    }

    public var sensorEndsAt: Date? {
        guard let activatedAt = sensorActivatedAt else {
            return nil
        }
        return activatedAt.addingTimeInterval(lifetime + G7Sensor.gracePeriod)
    }


    public var sensorFinishesWarmupAt: Date? {
        guard let activatedAt = sensorActivatedAt else {
            return nil
        }
        return activatedAt.addingTimeInterval(warmupDuration)
    }

    public var latestReading: G7GlucoseMessage? {
        return state.latestReading
    }

    public var lastConnect: Date? {
        return state.latestConnect
    }

    public var latestReadingTimestamp: Date? {
        return state.latestReadingTimestamp
    }

    /// One session, and one Bluetooth central inside it, for the manager's
    /// lifetime. Pairing reconfigures it in place.
    public let sensor: G7Sensor

    /// A session is valid while there is a sensor that can still deliver
    /// readings. Loop withholds closed loop without one, and refreshes its
    /// status display when this changes.
    public var cgmManagerStatus: LoopKit.CGMManagerStatus {
        let hasValidSensorSession: Bool
        switch lifecycleState {
        case .unpaired, .searching, .expired, .failed:
            hasValidSensorSession = false
        case .connecting, .warmup, .ok, .gracePeriod:
            hasValidSensorSession = true
        }
        return CGMManagerStatus(hasValidSensorSession: hasValidSensorSession, device: device)
    }

    public var lifecycleState: G7SensorLifecycleState {
        if state.sensorID == nil {
            guard state.sessionMode == .direct else {
                return .searching
            }
            let canAuthenticate = state.sharedKey != nil || state.pairingCode != nil
            return canAuthenticate ? .connecting : .unpaired
        }
        if let sensorEndsAt = sensorEndsAt, sensorEndsAt.timeIntervalSinceNow < 0 {
            return .expired
        }
        if let algorithmState = latestReading?.algorithmState {
            if algorithmState.isInWarmup {
                return .warmup
            }
            if algorithmState.sensorFailed {
                return .failed
            }
        }
        if let sensorExpiresAt = sensorExpiresAt, sensorExpiresAt.timeIntervalSinceNow < 0 {
            return .gracePeriod
        }
        return .ok
    }


    public func fetchNewDataIfNeeded(_ completion: @escaping (LoopKit.CGMReadingResult) -> Void) {
        sensor.resumeScanning()
        completion(.noData)
    }

    /// Creates a manager that watches a session the Dexcom app owns.
    ///
    /// The fallback for someone who cannot pair, typically because they are
    /// mid-session on a sensor whose code they no longer have. Prefer
    /// `init(pairingCode:peripheralIdentifier:sharedKey:)`.
    public convenience init() {
        self.init(sessionMode: .eavesdropping)
    }

    /// A manager with no sensor yet. Created at the start of setup, so the
    /// CGM exists and its device log carries the pairing from the first line;
    /// `applyPairingResult` completes it.
    public convenience init(sessionMode: G7SessionMode) {
        var state = G7CGMManagerState()
        state.sessionMode = sessionMode
        self.init(state: state, sensor: G7Sensor(mode: sessionMode, credentials: state.sensorCredentials))
    }

    /// Creates a manager for a sensor that has just been paired directly.
    ///
    /// With a `handoff`, the session is built around the central the pairing
    /// run used and takes over its authenticated connection, so the first
    /// reading arrives now rather than on the sensor's next advertisement.
    public convenience init(pairingCode: String, peripheralIdentifier: UUID?, sharedKey: Data?, handoff: G7PairingHandoff? = nil) {
        var state = G7CGMManagerState()
        state.sessionMode = .direct
        state.pairingCode = pairingCode
        state.peripheralIdentifier = peripheralIdentifier
        state.sharedKey = sharedKey
        state.pairedAt = Date()

        let sensor: G7Sensor
        if let handoff = handoff {
            sensor = G7Sensor(mode: .direct, credentials: state.sensorCredentials, bluetoothManager: handoff.bluetoothManager)
        } else {
            sensor = G7Sensor(mode: .direct, credentials: state.sensorCredentials)
        }
        self.init(state: state, sensor: sensor)

        if let handoff = handoff {
            sensor.adoptAuthenticatedConnection(handoff.peripheralManager)
        }
    }

    public required convenience init?(rawState: RawStateValue) {
        let state = G7CGMManagerState(rawValue: rawState)
        self.init(state: state, sensor: G7Sensor(mode: state.sessionMode, credentials: state.sensorCredentials))
        sensor.needsVersionInfo = state.extendedVersion == nil
    }

    init(state: G7CGMManagerState, sensor: G7Sensor) {
        lockedState = Locked(state)
        self.sensor = sensor
        sensor.delegate = self
        sensor.latestReadingDate = state.latestReadingTimestamp
        // A calibration entered before the app was last terminated is still owed to the sensor.
        if let calibration = state.calibration, calibration.outcome == .pending {
            sensor.calibrate(glucose: calibration.glucose, at: calibration.enteredAt)
        }
        // A grace period may have been in flight when the app was last terminated.
        restorePendingSuspectedSessionEnd()
    }


    /// How this manager gets its readings.
    public var sessionMode: G7SessionMode {
        state.sessionMode
    }

    /// Adopts the result of a pairing run, switching to direct mode.
    ///
    /// Used both to upgrade an eavesdropping session and to re-pair after
    /// replacing a sensor, so it deliberately forgets the previous sensor's
    /// identity: which physical sensor was just paired is not knowable until
    /// it reports a reading, and the first one re-establishes activation time
    /// and identity anyway.
    ///
    /// The session object and its Bluetooth central survive; the pairing run
    /// borrowed that same central, and `handoff` carries the connection it
    /// authenticated so the session can continue on it.
    /// Switches the session to direct authentication with the sensor just
    /// paired. `sensorName` is the paired peripheral's name, taken from the
    /// hand-off when there is one; when it names the sensor already being
    /// followed (an eavesdropper pairing with its own sensor), the session
    /// keeps its identity, readings and alerts and only the mode changes.
    /// Otherwise the current sensor is closed out and kept as the previous
    /// one, and the new sensor's identity is learned from its first reading.
    public func applyPairingResult(pairingCode: String, peripheralIdentifier: UUID?, sharedKey: Data?, handoff: G7PairingHandoff? = nil, sensorName: String? = nil) {
        let pairedName = sensorName ?? handoff?.peripheralManager.peripheral.name
        let isSameSensor: Bool
        if let pairedName = pairedName, let currentID = state.sensorID, G7Sensor.isSensorName(pairedName) {
            isSameSensor = pairedName.suffix(2) == currentID.suffix(2)
        } else {
            isSameSensor = false
        }

        cancelSuspectedSessionEndScan()

        if isSameSensor {
            logDeviceCommunication("Paired directly with \(state.sensorID!), the sensor already being followed; switching out of eavesdropping mode and keeping its session.", type: .connection)
        } else {
            logDeviceCommunication("Paired with a sensor directly; switching out of eavesdropping mode.", type: .connection)
            retractAllLifecycleAlerts()
            recordSensorEndIfNeeded()
            archiveCurrentSensor(reason: .replaced)
        }

        let newState = mutateState { state in
            state.sessionMode = .direct
            state.pairedAt = Date()
            state.sensorFailureMessage = nil
            state.sensorFailedAt = nil
            state.pairingCode = pairingCode
            state.peripheralIdentifier = peripheralIdentifier
            state.sharedKey = sharedKey
            state.lastAuthenticationFailure = nil
            state.lastAuthenticationFailureDate = nil
            if !isSameSensor {
                state.calibration = nil
                state.calibrationBounds = nil
                state.calibrationBoundsDate = nil
                state.sensorID = nil
                state.activatedAt = nil
                state.extendedVersion = nil
                state.transmitterVersion = nil
                state.latestReading = nil
                state.latestReadingTimestamp = nil
                state.lifecycleAlertsScheduledFor = nil
                state.sensorFailedAlertIssuedFor = nil
                state.sensorEndRecordedFor = nil
            }
        }

        sensor.reconfigure(mode: .direct, credentials: newState.sensorCredentials)
        sensor.latestReadingDate = newState.latestReadingTimestamp
        if let handoff = handoff {
            assert(handoff.bluetoothManager === sensor.bluetoothManager, "pairing must borrow the session's central")
            sensor.adoptAuthenticatedConnection(handoff.peripheralManager)
        } else {
            sensor.resumeScanning()
        }
    }

    public var rawState: RawStateValue {
        return state.rawValue
    }

    public var debugDescription: String {
        let lines = [
            "## G7CGMManager",
            "sensorID: \(String(describing: state.sensorID))",
            "activatedAt: \(String(describing: state.activatedAt))",
            "latestReading: \(String(describing: state.latestReading))",
            "latestReadingTimestamp: \(String(describing: state.latestReadingTimestamp))",
            "latestConnect: \(String(describing: state.latestConnect))",
            "sessionMode: \(state.sessionMode.rawValue)",
            "hasSharedKey: \(state.sharedKey != nil)",
            "hasPairingCode: \(state.pairingCode != nil)",
            "peripheralIdentifier: \(String(describing: state.peripheralIdentifier))",
            "lifecycleState: \(lifecycleState)",
            "lifecycleAlertsScheduledFor: \(String(describing: state.lifecycleAlertsScheduledFor))",
            "sensorFailedAlertIssuedFor: \(String(describing: state.sensorFailedAlertIssuedFor))",
            "lastAuthenticationFailure: \(String(describing: state.lastAuthenticationFailure))",
            "hasDelegate: \(cgmManagerDelegate != nil)",
            "pairedAt: \(String(describing: state.pairedAt))",
            "sensorFailure: \(String(describing: state.sensorFailureMessage)) at \(String(describing: state.sensorFailedAt))",
            "previousSensor: \(String(describing: state.previousSensor?.rawValue))",
        ]
        return lines.joined(separator: "\n")
    }

    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier) async throws { }

    public func getSoundBaseURL() -> URL? { return nil }
    public func getSounds() -> [Alert.Sound] { return [] }

    public let pluginIdentifier: String = "G7CGMManager"

    /// The model of the sensor in use, once one is known. G7 until then; the
    /// three models share one plugin and one protocol.
    public var sensorModel: G7SensorModel {
        state.sensorID.flatMap(G7SensorModel.init(advertisedName:)) ?? .g7
    }

    public var localizedTitle: String {
        sensorModel.localizedTitle
    }

    public let isOnboarded = true   // No distinction between created and onboarded

    public var appURL: URL? {
        return nil
    }

    public func scanForNewSensor() {
        cancelSuspectedSessionEndScan()
        retractAllLifecycleAlerts()
        recordSensorEndIfNeeded()
        archiveCurrentSensor(reason: .replaced)

        logDeviceCommunication("Forgetting existing sensor and starting scan for new sensor.", type: .connection)

        mutateState { state in
            state.sensorID = nil
            state.activatedAt = nil
            state.extendedVersion = nil
            state.transmitterVersion = nil
            // Only ever valid for the sensor being forgotten. Keeping them
            // would make every candidate fail its handshake.
            state.pairingCode = nil
            state.sharedKey = nil
            state.peripheralIdentifier = nil
            state.lifecycleAlertsScheduledFor = nil
            state.sensorFailedAlertIssuedFor = nil
            state.sensorEndRecordedFor = nil
            state.pairedAt = nil
            state.sensorFailureMessage = nil
            state.sensorFailedAt = nil
        }
        sensor.scanForNewSensor()
    }

    private var device: HKDevice? {
        return HKDevice(
            name: state.sensorID ?? "Unknown",
            manufacturer: "Dexcom",
            model: sensorModel.displayName,
            hardwareVersion: nil,
            firmwareVersion: state.transmitterVersion?.firmwareVersion,
            softwareVersion: "CGMBLEKit" + String(G7SensorKitVersionNumber),
            localIdentifier: nil,
            udiDeviceIdentifier: "00386270001863"
        )
    }

    public func logDeviceCommunication(_ message: String, type: DeviceLogEntryType = .send) {
        self.cgmManagerDelegate?.deviceManager(self, logEventForDeviceIdentifier: state.sensorID, type: type, message: message, completion: nil)
    }

    private func updateDelegate(with result: CGMReadingResult) {
        delegateQueue?.async {
            self.cgmManagerDelegate?.cgmManager(self, hasNew: result)
        }
    }
}

extension G7CGMManager {
    /// Tears the session down and retracts every alert before Loop drops
    /// this manager.
    ///
    /// Alerts outlive the manager: Loop's alert store keeps them for its whole
    /// cache window, and at launch it replays any past-due delayed alert as
    /// immediate until the user acknowledges it. A deleted CGM's scheduled
    /// expiry reminders would keep firing for weeks (LibreLoop #13). The
    /// retractions are queued on the delegate queue ahead of the deletion
    /// notification, so they land before Loop releases us. LoopKit's default
    /// `delete` only notifies, so the notification is re-issued here.
    public func delete(completion: @escaping () -> Void) {
        cancelSuspectedSessionEndScan()
        sensor.stopScanning()
        retractAllLifecycleAlerts()
        recordSensorEndIfNeeded()
        archiveCurrentSensor(reason: .deleted)
        notifyDelegateOfDeletion(completion: completion)
    }

    // MARK: - Session events

    /// Keeps the current sensor as `previousSensor` before it is let go, the
    /// way the pump plugins keep their previous pod: what it was, how and
    /// when it was paired, and how it ended.
    private func archiveCurrentSensor(reason: G7SensorRecord.EndReason) {
        guard let sensorID = state.sensorID else {
            return
        }
        let record = G7SensorRecord(
            sensorID: sensorID,
            pairingCode: state.pairingCode,
            serialNumber: state.transmitterVersion?.serialNumberString,
            firmwareVersion: state.transmitterVersion?.firmwareVersion,
            pairedAt: state.pairedAt,
            activatedAt: state.activatedAt,
            sessionLength: state.extendedVersion?.sessionLength,
            warmupDuration: state.extendedVersion?.warmupDuration,
            endedAt: Date(),
            endReason: reason,
            failureMessage: state.sensorFailureMessage,
            failedAt: state.sensorFailedAt
        )
        mutateState { state in
            state.previousSensor = record
        }
    }

    /// Closes the current sensor's session in Loop's CGM event history, once.
    /// Paired with the `sensorStart` recorded at discovery, so the history
    /// brackets each session; Loop tolerates a missing end, which is why this
    /// is also safe to call speculatively when a sensor is forgotten.
    private func recordSensorEndIfNeeded(failureMessage: String? = nil) {
        guard let sensorID = state.sensorID, state.sensorEndRecordedFor != sensorID else {
            return
        }
        let event = PersistedCgmEvent(
            date: Date(),
            type: .sensorEnd,
            deviceIdentifier: sensorID,
            failureMessage: failureMessage
        )
        delegate.notify { delegate in
            delegate?.cgmManager(self, hasNew: [event])
        }
        mutateState { state in
            state.sensorEndRecordedFor = sensorID
        }
    }

    // MARK: - Lifecycle alerts

    private func issueLifecycleAlert(_ alert: G7LifecycleAlert, trigger: Alert.Trigger = .immediate) {
        let loopAlert = alert.alert(managerIdentifier: pluginIdentifier, trigger: trigger)
        switch trigger {
        case .delayed(let interval):
            logDeviceCommunication("Scheduling alert \(alert.rawValue) in \(Int(interval))s", type: .connection)
        default:
            logDeviceCommunication("Issuing alert \(alert.rawValue)", type: .connection)
        }
        delegate.notify { delegate in
            Task {
                await delegate?.issueAlert(loopAlert)
            }
        }
    }

    private func retractLifecycleAlert(_ alert: G7LifecycleAlert) {
        let identifier = alert.identifier(managerIdentifier: pluginIdentifier)
        delegate.notify { delegate in
            Task {
                await delegate?.retractAlert(identifier: identifier)
            }
        }
    }

    private func retractAllLifecycleAlerts() {
        G7LifecycleAlert.allCases.forEach(retractLifecycleAlert)
    }

    /// (Re)schedules the session-timed alerts for the current sensor and
    /// lifetime. Cheap to call often: nothing is issued unless the sensor or
    /// its lifetime changed since the last time, which is what makes a
    /// 15-day sensor's later extended-version report reschedule correctly
    /// without every relaunch re-issuing the same notifications.
    private func scheduleSessionTimedAlerts() {
        guard let sensorID = state.sensorID, let expiresAt = sensorExpiresAt, let endsAt = sensorEndsAt else {
            return
        }
        let key = "\(sensorID)|\(expiresAt.timeIntervalSince1970)"
        guard state.lifecycleAlertsScheduledFor != key else {
            return
        }

        G7LifecycleAlert.sessionTimed.forEach(retractLifecycleAlert)
        for (alert, delay) in G7LifecycleAlertSchedule.delays(sensorExpiresAt: expiresAt, sensorEndsAt: endsAt, now: Date()) {
            issueLifecycleAlert(alert, trigger: .delayed(interval: delay))
        }
        mutateState { state in
            state.lifecycleAlertsScheduledFor = key
        }
    }

    /// Arms the signal-loss alert to fire if no further reading arrives in
    /// time. Called on every reading, so it keeps being pushed back while
    /// readings flow and only ever fires after they stop.
    private func rearmSignalLossAlert() {
        retractLifecycleAlert(.signalLoss)
        issueLifecycleAlert(.signalLoss, trigger: .delayed(interval: G7LifecycleAlert.signalLossInterval))
    }

    private func raiseSensorFailedAlertIfNeeded(for message: G7GlucoseMessage) {
        guard message.algorithmState.sensorFailed, let sensorID = state.sensorID,
              state.sensorFailedAlertIssuedFor != sensorID
        else {
            return
        }
        issueLifecycleAlert(.sensorFailed)
        // A failed sensor will not send more readings; nothing to lose signal from.
        retractLifecycleAlert(.signalLoss)
        mutateState { state in
            state.sensorFailedAlertIssuedFor = sensorID
            state.sensorFailureMessage = String(describing: message.algorithmState)
            state.sensorFailedAt = Date()
        }
        recordSensorEndIfNeeded(failureMessage: String(describing: message.algorithmState))
    }

    // MARK: - G7StateObserver

    public func addStateObserver(_ observer: G7StateObserver, queue: DispatchQueue) {
        g7StateObservers.insert(observer, queue: queue)
    }

    public func removeStateObserver(_ observer: G7StateObserver) {
        g7StateObservers.removeElement(observer)
    }
}

extension G7CGMManager: G7SensorDelegate {
    public func sensor(_ sensor: G7Sensor, didDiscoverNewSensor name: String, activatedAt: Date) -> Bool {
        logDeviceCommunication("New sensor \(name) discovered, activated at \(activatedAt)", type: .connection)

        let shouldSwitchToNewSensor = true

        if shouldSwitchToNewSensor {
            sensor.cancelPendingCalibration()
            mutateState { state in
                state.sensorID = name
                state.activatedAt = activatedAt
                state.calibration = nil
                state.calibrationBounds = nil
                state.calibrationBoundsDate = nil
                state.peripheralIdentifier = sensor.credentials.peripheralIdentifier
                if state.pairedAt == nil {
                    state.pairedAt = Date()
                }
            }
            let event = PersistedCgmEvent(
                date: activatedAt,
                type: .sensorStart,
                deviceIdentifier: name,
                expectedLifetime: lifetime + G7Sensor.gracePeriod,
                warmupPeriod: warmupDuration
            )
            delegate.notify { delegate in
                delegate?.cgmManager(self, hasNew: [event])
            }
            scheduleSessionTimedAlerts()
        }

        return shouldSwitchToNewSensor
    }

    public func sensor(_ sensor: G7Sensor, didAuthenticateWith sharedKey: Data, deviceName: String?) {
        logDeviceCommunication("Authenticated with the sensor directly.", type: .connection)
        mutateState { state in
            state.sharedKey = sharedKey
            state.peripheralIdentifier = sensor.credentials.peripheralIdentifier
            state.lastAuthenticationFailure = nil
            state.lastAuthenticationFailureDate = nil
        }
    }

    public func sensorDidInvalidateSharedKey(_ sensor: G7Sensor) {
        logDeviceCommunication("The saved sensor key is no longer accepted; the next connection will pair again.", type: .connection)
        mutateState { state in
            state.sharedKey = nil
        }
    }

    public func sensor(_ sensor: G7Sensor, didReceive transmitterVersion: TransmitterVersionMessage) {
        mutateState { state in
            state.transmitterVersion = transmitterVersion
        }
    }

    // MARK: - Calibration

    /// The latest calibration entered for this sensor.
    public var calibration: G7CalibrationRecord? {
        state.calibration
    }

    /// Whether a calibration is still waiting for the sensor's next connection.
    public var hasPendingCalibration: Bool {
        sensor.queuedCalibration != nil
    }

    /// Whether the sensor will take a calibration right now: a direct session
    /// with a live, warmed-up sensor. The sensor refuses them during warmup.
    public var canCalibrate: Bool {
        sessionMode == .direct && lifecycleState == .ok
    }

    /// Hands a meter glucose (mg/dL, taken at `date`) to the sensor on its
    /// next connection. Replaces any calibration still waiting.
    public func calibrate(glucose: UInt16, at date: Date = Date()) {
        logDeviceCommunication("Calibration \(glucose) mg/dL entered; queued for the sensor's next connection", type: .connection)
        mutateState { state in
            state.calibration = G7CalibrationRecord(glucose: glucose, enteredAt: date)
        }
        sensor.calibrate(glucose: glucose, at: date)
    }

    public func cancelPendingCalibration() {
        sensor.cancelPendingCalibration()
        logDeviceCommunication("Queued calibration cancelled", type: .connection)
        mutateState { state in
            if state.calibration?.outcome == .pending {
                state.calibration = nil
            }
        }
    }

    public func sensor(_ sensor: G7Sensor, didReceiveCalibrationResponse response: G7CalibrateRxMessage) {
        mutateState { state in
            state.calibration?.outcome = response.accepted
                ? .accepted(at: Date())
                : .rejected(status: response.status, at: Date())
        }
    }

    public func sensor(_ sensor: G7Sensor, didReadCalibrationBounds bounds: G7CalibrationBoundsMessage) {
        mutateState { state in
            state.calibrationBounds = bounds
            state.calibrationBoundsDate = Date()
            if case .accepted = state.calibration?.outcome {
                state.calibration?.processingStatus = bounds.processingStatus
            }
        }
        // Folding a calibration in takes the sensor a reading or two; keep
        // asking on each connection until it says it is done.
        if bounds.processingStatus == .inProgress {
            sensor.requestCalibrationBounds()
        }
    }

    public func sensor(_ sensor: G7Sensor, didReceive extendedVersion: ExtendedVersionMessage) {
        mutateState { state in
            state.extendedVersion = extendedVersion
        }
        // A 15-day sensor moves its expiry out; the timed alerts follow it.
        scheduleSessionTimedAlerts()
    }

    public func sensorDidConnect(_ sensor: G7Sensor, name: String) {
        mutateState { state in
            state.latestConnect = Date()
        }
        logDeviceCommunication("Sensor connected", type: .connection)
    }

    public func sensorDisconnected(_ sensor: G7Sensor, suspectedEndOfSession: Bool) {
        logDeviceCommunication("Sensor disconnected: suspectedEndOfSession=\(suspectedEndOfSession)", type: .connection)
        if suspectedEndOfSession {
            scheduleScanAfterSuspectedSessionEnd()
        }
    }

    /// A disconnect before authentication usually means the session was stopped,
    /// but the same signature occurs on transient BLE handshake failures, where
    /// forgetting the sensor immediately causes a long re-discovery outage.
    /// Instead, keep tracking the current sensor and only scan for a new one if
    /// communication does not resume within the grace period.
    private func scheduleScanAfterSuspectedSessionEnd() {
        // `suspectedSessionEndAt` is the single record of a live grace period: it
        // says whether one is running, identifies it, and survives termination.
        guard state.suspectedSessionEndAt == nil else {
            logDeviceCommunication("Suspected session end during active grace period; original deadline unchanged.", type: .connection)
            return
        }

        let graceStart = Date()
        mutateState { state in
            state.suspectedSessionEndAt = graceStart
        }

        logDeviceCommunication("Suspected session end; waiting \(suspectedSessionEndGracePeriod.minutes) minutes for communication to resume before scanning for new sensor.", type: .connection)
        scheduleGraceExpiry(graceStart: graceStart, after: suspectedSessionEndGracePeriod)
    }

    private func scheduleGraceExpiry(graceStart: Date, after delay: TimeInterval) {
        // Wall-clock deadline: a mach-time deadline pauses while the device
        // sleeps, which could postpone detection of a genuinely ended session.
        // Not cancellable, and does not need to be -- the expiry re-reads
        // `suspectedSessionEndAt` and no-ops unless it still owns the window.
        DispatchQueue.global(qos: .utility).asyncAfter(wallDeadline: .now() + delay) { [weak self] in
            self?.handleSuspectedSessionEndGraceExpiry(graceStart: graceStart)
        }
    }

    func handleSuspectedSessionEndGraceExpiry(graceStart: Date) {
        // Cleared by resumed communication, or replaced by a later grace period.
        guard state.suspectedSessionEndAt == graceStart else {
            logDeviceCommunication("Communication received during suspected session end grace period; keeping sensor.", type: .connection)
            return
        }

        logDeviceCommunication("No sensor communication since suspected session end.", type: .connection)
        scanForNewSensor()
    }

    /// Clearing the marker is the cancellation: a pending expiry finds a grace
    /// start that is no longer current and does nothing.
    private func cancelSuspectedSessionEndScan() {
        // Guarded because this runs on every glucose and backfill message, and
        // mutateState notifies observers and persists.
        guard state.suspectedSessionEndAt != nil else { return }
        mutateState { state in
            state.suspectedSessionEndAt = nil
        }
    }

    /// Re-establish a grace period that was in flight when the app was last
    /// terminated. The expiry is dispatched in memory and does not survive, so
    /// without this a genuinely ended session would be tracked forever -- the
    /// sensor never advertises again and nothing re-arms the scan.
    private func restorePendingSuspectedSessionEnd() {
        guard let graceStart = state.suspectedSessionEndAt else { return }

        // Normally resumed communication has already cleared the marker. This
        // covers the case where that clear was not persisted before we exited.
        if let latestReadingTimestamp = state.latestReadingTimestamp, latestReadingTimestamp > graceStart {
            cancelSuspectedSessionEndScan()
            return
        }

        let remaining = graceStart.addingTimeInterval(suspectedSessionEndGracePeriod).timeIntervalSinceNow
        guard remaining > 0 else {
            // The window elapsed while we were not running, with nothing heard since.
            logDeviceCommunication("Grace period for suspected session end expired while app was not running.", type: .connection)
            scanForNewSensor()
            return
        }

        logDeviceCommunication("Resuming suspected session end grace period; \(Int(remaining / 60)) minutes remaining.", type: .connection)
        scheduleGraceExpiry(graceStart: graceStart, after: remaining)
    }

    public func sensor(_ sensor: G7Sensor, logComms comms: String) {
        logDeviceCommunication(comms, type: .receive)
    }

    public func sensor(_ sensor: G7Sensor, log message: String, type: DeviceLogEntryType) {
        logDeviceCommunication(message, type: type)
    }


    /// A refusal the user can act on, as opposed to the timeouts a flaky link
    /// produces every so often.
    private func authenticationFailureDescription(for error: Error) -> String? {
        switch error {
        case G7AuthenticatorError.rejected(_, .noAppKey):
            // Recovered unattended by the session; nothing for the user to do.
            return nil
        case G7AuthenticatorError.rejected, G7AuthenticatorError.challengeMismatch, G7AuthenticatorError.unexpectedResponse:
            return String(describing: error)
        default:
            return nil
        }
    }

    public func sensor(_ sensor: G7Sensor, didError error: Error) {
        if let description = authenticationFailureDescription(for: error) {
            let isNew = state.lastAuthenticationFailure == nil
            mutateState { state in
                state.lastAuthenticationFailure = description
                state.lastAuthenticationFailureDate = Date()
            }
            if isNew {
                issueLifecycleAlert(.connectionRefused)
            }
        }
        logDeviceCommunication("Sensor error \(error)", type: .error)
    }

    public func sensor(_ sensor: G7Sensor, didRead message: G7GlucoseMessage) {
        if state.lastAuthenticationFailure != nil {
            mutateState { state in
                state.lastAuthenticationFailure = nil
                state.lastAuthenticationFailureDate = nil
            }
            retractLifecycleAlert(.connectionRefused)
        }
        rearmSignalLossAlert()
        raiseSensorFailedAlertIfNeeded(for: message)

        // Receiving any glucose message proves the session is still active.
        cancelSuspectedSessionEndScan()

        guard message != latestReading else {
            logDeviceCommunication("Sensor reading duplicate: \(message)", type: .error)
            updateDelegate(with: .noData)
            return
        }

        if message.algorithmState.sensorFailed {
            logDeviceCommunication("Detected failed sensor... scanning for new sensor.", type: .receive)
            scanForNewSensor()
        }

        if message.algorithmState == .known(.sessionEnded) {
            logDeviceCommunication("Detected session ended... scanning for new sensor.", type: .receive)
            scanForNewSensor()
        }


        guard let activationDate = sensor.activationDate else {
            logDeviceCommunication("Unable to process sensor reading without activation date.", type: .error)
            return
        }

        logDeviceCommunication("Sensor didRead \(message)", type: .receive)

        let latestReadingTimestamp = activationDate.addingTimeInterval(TimeInterval(message.glucoseTimestamp))

        mutateState { state in
            state.latestReading = message
            state.latestReadingTimestamp = latestReadingTimestamp
        }

        guard let glucose = message.glucose else {
            updateDelegate(with: .noData)
            return
        }

        guard message.hasReliableGlucose else {
            updateDelegate(with: .error(AlgorithmError.unreliableState(message.algorithmState)))
            return
        }

        let unit = LoopUnit.milligramsPerDeciliter
        let quantity = LoopQuantity(unit: unit, doubleValue: Double(min(max(glucose, GlucoseLimits.minimum), GlucoseLimits.maximum)))

        updateDelegate(with: .newData([
            NewGlucoseSample(
                date: latestReadingTimestamp,
                quantity: quantity,
                condition: message.condition,
                trend: message.trendType,
                trendRate: message.trendRate,
                isDisplayOnly: message.glucoseIsDisplayOnly,
                wasUserEntered: message.glucoseIsDisplayOnly,
                syncIdentifier: generateSyncIdentifier(timestamp: message.glucoseTimestamp),
                device: device
            )
        ]))
    }

    private func generateSyncIdentifier(timestamp: UInt32) -> String {
        guard let activatedAt = state.activatedAt, let sensorID = state.sensorID else {
            return "invalid"
        }

        return "\(activatedAt.timeIntervalSince1970.hours) \(sensorID) \(timestamp)"
    }

    public func sensor(_ sensor: G7Sensor, didReadBackfill backfill: [G7BackfillMessage]) {
        // Backfill likewise proves the session is still active.
        cancelSuspectedSessionEndScan()

        for msg in backfill {
            logDeviceCommunication("Sensor didReadBackfill \(msg)", type: .receive)
        }

        guard let activationDate = sensor.activationDate else {
            log.error("Unable to process backfill without activation date.")
            return
        }

        // A backfill record can be the newest reading we hold, when the
        // sensor's reply to the reading request itself was lost. It keeps
        // the session current and the signal-loss alert armed just as a
        // live reading would.
        if let newest = backfill.map({ $0.timestamp }).max() {
            let newestDate = activationDate.addingTimeInterval(TimeInterval(newest))
            if newestDate > (state.latestReadingTimestamp ?? .distantPast) {
                mutateState { state in
                    state.latestReadingTimestamp = newestDate
                }
                rearmSignalLossAlert()
            }
        }

        let unit = LoopUnit.milligramsPerDeciliter

        let samples = backfill.compactMap { entry -> NewGlucoseSample? in
            guard let glucose = entry.glucose else {
                return nil
            }

            guard entry.hasReliableGlucose else {
                logDeviceCommunication("Backfill reading unreliable: \(entry)", type: .receive)
                return nil
            }

            let quantity = LoopQuantity(unit: unit, doubleValue: Double(min(max(glucose, GlucoseLimits.minimum), GlucoseLimits.maximum)))

            return NewGlucoseSample(
                date: activationDate.addingTimeInterval(TimeInterval(entry.timestamp)),
                quantity: quantity,
                condition: entry.condition,
                trend: entry.trendType,
                trendRate: entry.trendRate,
                isDisplayOnly: entry.glucoseIsDisplayOnly,
                wasUserEntered: entry.glucoseIsDisplayOnly,
                syncIdentifier: generateSyncIdentifier(timestamp: entry.timestamp),
                device: device
            )
        }

        updateDelegate(with: .newData(samples))
    }

    public func sensorConnectionStatusDidUpdate(_ sensor: G7Sensor) {
        g7StateObservers.forEach { (observer) in
            observer.g7ConnectionStatusDidChange()
        }
    }
}

extension G7BackfillMessage {
    public var trendRate: LoopQuantity? {
        guard let trend = trend else {
            return nil
        }
        return LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: trend)
    }
}

extension G7GlucoseMessage: GlucoseDisplayable {
    public var isStateValid: Bool {
        return hasReliableGlucose
    }

    public var trendRate: LoopQuantity? {
        guard let trend = trend else {
            return nil
        }
        return LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: trend)
    }

    public var glucoseQuantity: LoopQuantity? {
        guard let glucose = glucose else {
            return nil
        }
        return LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(glucose))
    }

    public var isLocal: Bool {
        return true
    }

    public var glucoseRangeCategory: LoopKit.GlucoseRangeCategory? {
        guard let glucose = glucose else {
            return nil
        }

        if glucose < GlucoseLimits.minimum {
            return .belowRange
        } else if glucose > GlucoseLimits.maximum {
            return .aboveRange
        } else {
            return nil
        }
    }
}
