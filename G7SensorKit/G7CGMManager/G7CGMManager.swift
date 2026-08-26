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

    /// Pending deferred scan-for-new-sensor, scheduled on a suspected session end
    /// and cancelled when sensor communication resumes.
    private let suspectedSessionEndScanItem = Locked<DispatchWorkItem?>(nil)

    /// When the sensor last communicated (glucose or backfill message). Used to
    /// resolve the race between an expiring grace period and an arriving message.
    private let lastSensorCommsDate = Locked<Date?>(nil)

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
        return state.uploadReadings
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

    public var uploadReadings: Bool {
        get {
            return state.uploadReadings
        }
        set {
            mutateState { state in
                state.uploadReadings = newValue
            }
        }
    }

    public let sensor: G7Sensor

    public var cgmManagerStatus: LoopKit.CGMManagerStatus {
        return CGMManagerStatus(hasValidSensorSession: true, device: device)
    }

    public var lifecycleState: G7SensorLifecycleState {
        if state.sensorID == nil {
            return .searching
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

    public convenience init() {
        self.init(state: G7CGMManagerState(), sensor: G7Sensor(sensorID: nil))
    }

    public required convenience init?(rawState: RawStateValue) {
        let state = G7CGMManagerState(rawValue: rawState)
        self.init(state: state, sensor: G7Sensor(sensorID: state.sensorID))
        sensor.needsVersionInfo = state.extendedVersion == nil
    }

    init(state: G7CGMManagerState, sensor: G7Sensor) {
        lockedState = Locked(state)
        self.sensor = sensor
        sensor.delegate = self
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
            "uploadReadings: \(String(describing: state.uploadReadings))",
        ]
        return lines.joined(separator: "\n")
    }

    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier) async throws { }

    public func getSoundBaseURL() -> URL? { return nil }
    public func getSounds() -> [Alert.Sound] { return [] }

    public let pluginIdentifier: String = "G7CGMManager"

    public let localizedTitle = LocalizedString("Dexcom G7", comment: "CGM display title")

    public let isOnboarded = true   // No distinction between created and onboarded

    public var appURL: URL? {
        return nil
    }

    public func scanForNewSensor() {
        cancelSuspectedSessionEndScan()

        logDeviceCommunication("Forgetting existing sensor and starting scan for new sensor.", type: .connection)

        mutateState { state in
            state.sensorID = nil
            state.activatedAt = nil
            state.extendedVersion = nil
        }
        sensor.scanForNewSensor()
    }

    private var device: HKDevice? {
        return HKDevice(
            name: state.sensorID ?? "Unknown",
            manufacturer: "Dexcom",
            model: "G7",
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: "CGMBLEKit" + String(G7SensorKitVersionNumber),
            localIdentifier: nil,
            udiDeviceIdentifier: "00386270001863"
        )
    }

    func logDeviceCommunication(_ message: String, type: DeviceLogEntryType = .send) {
        self.cgmManagerDelegate?.deviceManager(self, logEventForDeviceIdentifier: state.sensorID, type: type, message: message, completion: nil)
    }

    private func updateDelegate(with result: CGMReadingResult) {
        delegateQueue?.async {
            self.cgmManagerDelegate?.cgmManager(self, hasNew: result)
        }
    }
}

extension G7CGMManager {
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
            mutateState { state in
                state.sensorID = name
                state.activatedAt = activatedAt
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
        }

        return shouldSwitchToNewSensor
    }

    public func sensor(_ sensor: G7Sensor, didReceive extendedVersion: ExtendedVersionMessage) {
        mutateState { state in
            state.extendedVersion = extendedVersion
        }
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
        let graceStart = Date()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleSuspectedSessionEndGraceExpiry(graceStart: graceStart)
        }

        var scheduled = false
        _ = suspectedSessionEndScanItem.mutate { item in
            if item == nil {
                item = workItem
                scheduled = true
            }
        }

        // A grace period is already running; keep its original deadline.
        guard scheduled else {
            logDeviceCommunication("Suspected session end during active grace period; original deadline unchanged.", type: .connection)
            return
        }

        logDeviceCommunication("Suspected session end; waiting \(suspectedSessionEndGracePeriod.minutes) minutes for communication to resume before scanning for new sensor.", type: .connection)
        // Wall-clock deadline: a mach-time deadline pauses while the device
        // sleeps, which could postpone detection of a genuinely ended session.
        DispatchQueue.global(qos: .utility).asyncAfter(wallDeadline: .now() + suspectedSessionEndGracePeriod, execute: workItem)
    }

    func handleSuspectedSessionEndGraceExpiry(graceStart: Date) {
        suspectedSessionEndScanItem.value = nil

        // A message may have arrived after this expiry was already dispatched;
        // any communication since the grace period began proves the session is alive.
        if let lastComms = lastSensorCommsDate.value, lastComms > graceStart {
            logDeviceCommunication("Communication received during suspected session end grace period; keeping sensor.", type: .connection)
            return
        }

        logDeviceCommunication("No sensor communication since suspected session end.", type: .connection)
        scanForNewSensor()
    }

    private func cancelSuspectedSessionEndScan() {
        var pendingItem: DispatchWorkItem?
        _ = suspectedSessionEndScanItem.mutate { item in
            pendingItem = item
            item = nil
        }
        pendingItem?.cancel()
    }

    public func sensor(_ sensor: G7Sensor, logComms comms: String) {
        logDeviceCommunication("Sensor comms \(comms)", type: .receive)
    }


    public func sensor(_ sensor: G7Sensor, didError error: Error) {
        logDeviceCommunication("Sensor error \(error)", type: .error)
    }

    public func sensor(_ sensor: G7Sensor, didRead message: G7GlucoseMessage) {

        // Receiving any glucose message proves the session is still active.
        lastSensorCommsDate.value = Date()
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
        lastSensorCommsDate.value = Date()
        cancelSuspectedSessionEndScan()

        for msg in backfill {
            logDeviceCommunication("Sensor didReadBackfill \(msg)", type: .receive)
        }

        guard let activationDate = sensor.activationDate else {
            log.error("Unable to process backfill without activation date.")
            return
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
