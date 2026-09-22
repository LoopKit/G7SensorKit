//
//  G7Sensor.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 9/24/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import CoreBluetooth
import LoopKit
import os.log


public protocol G7SensorDelegate: AnyObject {
    func sensorDidConnect(_ sensor: G7Sensor, name: String)

    func sensorDisconnected(_ sensor: G7Sensor, suspectedEndOfSession: Bool)

    func sensor(_ sensor: G7Sensor, didError error: Error)

    /// A received frame, as hex. Kept for the raw-receive lines.
    func sensor(_ sensor: G7Sensor, logComms comms: String)

    /// A device-log entry of the given type: sends as hex, connection events,
    /// handshake narration. Mirrors what the pump plugins record.
    func sensor(_ sensor: G7Sensor, log message: String, type: DeviceLogEntryType)

    func sensor(_ sensor: G7Sensor, didRead glucose: G7GlucoseMessage)

    func sensor(_ sensor: G7Sensor, didReadBackfill backfill: [G7BackfillMessage])

    // If this returns true, then start following this sensor
    func sensor(_ sensor: G7Sensor, didDiscoverNewSensor name: String, activatedAt: Date) -> Bool

    func sensor(_ sensor: G7Sensor, didReceive extendedVersion: ExtendedVersionMessage)

    func sensor(_ sensor: G7Sensor, didReceive transmitterVersion: TransmitterVersionMessage)

    /// The sensor's answer to a calibration we sent.
    func sensor(_ sensor: G7Sensor, didReceiveCalibrationResponse response: G7CalibrateRxMessage)

    /// The sensor's calibration state, after a calibration or on request.
    func sensor(_ sensor: G7Sensor, didReadCalibrationBounds bounds: G7CalibrationBoundsMessage)

    // This is triggered for connection/disconnection events, and enabling/disabling scan
    func sensorConnectionStatusDidUpdate(_ sensor: G7Sensor)

    /// Direct mode only: a handshake produced a new shared key, which the
    /// caller must persist so later reconnects can skip the key exchange.
    func sensor(_ sensor: G7Sensor, didAuthenticateWith sharedKey: Data, deviceName: String?)

    /// Direct mode only: the stored shared key is no longer accepted by the
    /// sensor. It has been discarded; if a pairing code is still held, the
    /// next connection will run a full handshake.
    func sensorDidInvalidateSharedKey(_ sensor: G7Sensor)
}

public enum G7SensorError: Error {
    case authenticationError(String)
    case controlError(String)
    case observationError(String)
}

extension G7SensorError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .authenticationError(let description):
            return description
        case .controlError(let description):
            return description
        case .observationError(let description):
            return description
        }
    }
}

public enum G7SensorLifecycleState {
    /// No sensor known and nothing to pair with: an eavesdropping session
    /// waiting for the Dexcom app to start one.
    case searching
    /// Direct mode with nothing to connect to yet: the CGM was added but no
    /// sensor has been paired.
    case unpaired
    /// Paired, but the sensor has not reported its first reading yet. It
    /// links only briefly around each 5-minute reading, so this can last a
    /// few minutes after pairing.
    case connecting
    case warmup
    case ok
    case failed
    case gracePeriod
    case expired
}

/// Everything needed to reach a particular sensor. Held behind a lock: the
/// handshake completes on the peripheral manager's queue, while scanning and
/// the public setters run elsewhere.
struct G7SensorCredentials: Equatable {
    /// The sensor's advertised name, which is also how a session recognizes
    /// its own sensor across reconnects.
    var sensorID: String?

    /// The 4-digit code printed on the applicator. Direct mode only, and only
    /// valid for the sensor it came with.
    var pairingCode: String?

    /// The key derived at pairing. Direct mode only; its presence is what
    /// lets a reconnect skip the key exchange.
    var sharedKey: Data?

    /// The paired sensor's CoreBluetooth identifier, so a relaunch can go
    /// straight to it instead of waiting for an advertisement.
    var peripheralIdentifier: UUID?
}


public final class G7Sensor: G7BluetoothManagerDelegate {
    public static let defaultLifetime = TimeInterval(hours: 10 * 24)
    public static let defaultWarmupDuration = TimeInterval(minutes: 27)
    public static let gracePeriod = TimeInterval(hours: 12)

    /// How far back to ask the sensor to backfill after a direct-mode
    /// reconnect when nothing is known about the gap (a fresh pairing).
    static let backfillWindow = TimeInterval(hours: 3)

    /// The most a single backfill request will ask for when the gap since
    /// the last reading is known. Anything the sensor no longer holds it
    /// simply omits.
    static let maximumBackfillWindow = TimeInterval(hours: 24)

    public weak var delegate: G7SensorDelegate?

    /// How readings are obtained. Changed in place by `reconfigure`, so the
    /// Bluetooth central (and any connection it holds) survives a pairing.
    public private(set) var mode: G7SessionMode

    // MARK: - Session state, confined to `bluetoothManager.managerQueue`

    /// The initial activation date of the sensor
    var activationDate: Date?

    /// The initial activation date of the sensor
    var needsVersionInfo: Bool = false

    /// Used to detect connections that do not authenticate, signalling possible sensor switchover
    private var pendingAuth: Bool = false

    /// The backfill data buffer
    private var backfillBuffer: [G7BackfillMessage] = []

    /// When the newest reading we hold was taken. Sizes the backfill request
    /// after a direct-mode reconnect. Seeded by the manager from its saved
    /// state, so a relaunch asks for the gap rather than a default window.
    var latestReadingDate: Date?

    /// Set when a session opens; the backfill request goes out once the
    /// reading reply has arrived, so the sensor never has two of our
    /// commands outstanding. Confined to `bluetoothManager.managerQueue`.
    private var backfillRequestPending = false

    /// A calibration waiting for the sensor's next connection: the link is
    /// only up for a few seconds around each reading, so one entered between
    /// readings has to wait. Newest wins. Settable from any queue.
    private let lockedPendingCalibration = Locked<(glucose: UInt16, date: Date)?>(nil)

    /// Whether to ask for the calibration state on the next connection.
    private let lockedCalibrationBoundsRequestPending = Locked(false)

    // MARK: -

    private let log = OSLog(category: "G7Sensor")

    /// Shared with a pairing run, which borrows it as its central; see
    /// `G7BluetoothManager.init`.
    let bluetoothManager: G7BluetoothManager

    private let delegateQueue = DispatchQueue(label: "com.loopkit.G7Sensor.delegateQueue", qos: .unspecified)

    private let lockedCredentials: Locked<G7SensorCredentials>

    var credentials: G7SensorCredentials {
        lockedCredentials.value
    }

    public var sensorID: String? {
        lockedCredentials.value.sensorID
    }

    /// Which of the sensor's display slots this session takes: a phone by
    /// default; a watch app would take its own, alongside the phone's.
    let displayType: G7DisplayType

    convenience init(mode: G7SessionMode, credentials: G7SensorCredentials, displayType: G7DisplayType = .phone) {
        self.init(mode: mode, credentials: credentials, bluetoothManager: G7BluetoothManager(), displayType: displayType)
    }

    init(mode: G7SessionMode, credentials: G7SensorCredentials, bluetoothManager: G7BluetoothManager, displayType: G7DisplayType = .phone) {
        self.mode = mode
        self.displayType = displayType
        self.lockedCredentials = Locked(credentials)
        self.bluetoothManager = bluetoothManager
        bluetoothManager.delegate = self
        bluetoothManager.setActivePeripheralIdentifier(credentials.peripheralIdentifier)
    }

    private func mutateCredentials(_ changes: (inout G7SensorCredentials) -> Void) {
        _ = lockedCredentials.mutate(changes)
    }

    /// Whether a peripheral is the sensor these credentials describe.
    ///
    /// By identifier once one is known. Otherwise by the last two characters
    /// of the name, because the name itself changes: a sensor advertises as
    /// "DXCMxx" but reports "Dexcomxx" over GAP once connected, and a
    /// peripheral retrieved for a reconnect carries the latter. Comparing
    /// whole names silently stopped every reconnect after the first.
    static func isSensor(identifier: UUID, name: String?, describedBy credentials: G7SensorCredentials) -> Bool {
        if let known = credentials.peripheralIdentifier {
            return identifier == known
        }
        guard let sensorID = credentials.sensorID, let name = name else {
            return false
        }
        return name.suffix(2) == sensorID.suffix(2)
    }

    /// Names a G7-family sensor uses: the model prefixes ("DXCMxx",
    /// "DX02xx", "DX01xx") in advertisements, "Dexcomxx" once connected.
    static func isSensorName(_ name: String) -> Bool {
        G7SensorModel.isFamilyName(name)
    }

    private func isOurSensor(_ peripheralManager: G7PeripheralManager) -> Bool {
        G7Sensor.isSensor(
            identifier: peripheralManager.peripheral.identifier,
            name: peripheralManager.peripheral.name,
            describedBy: lockedCredentials.value
        )
    }

    private func logToDevice(_ message: String, type: DeviceLogEntryType) {
        delegateQueue.async {
            self.delegate?.sensor(self, log: message, type: type)
        }
    }

    private func logSend(_ data: Data, on characteristic: CGMServiceCharacteristicUUID) {
        logToDevice("\(characteristic) \(data.hexadecimalString)", type: .send)
    }

    /// Points this session at a different sensor (or a different way of
    /// reaching the same one) without rebuilding it. Everything learned about
    /// the previous sensor is forgotten; the first reading re-establishes it.
    func reconfigure(mode: G7SessionMode, credentials: G7SensorCredentials) {
        self.mode = mode
        lockedCredentials.value = credentials
        activationDate = nil
        latestReadingDate = nil
        needsVersionInfo = true
        pendingAuth = false
        backfillBuffer = []
        bluetoothManager.delegate = self
        bluetoothManager.setActivePeripheralIdentifier(credentials.peripheralIdentifier)
    }

    /// Takes over a connection on which a pairing run has just authenticated,
    /// and opens the session on it straight away. Without this the sensor
    /// would be dropped and reconnected on its next 5-minute advertisement,
    /// leaving a gap right after "paired".
    func adoptAuthenticatedConnection(_ peripheralManager: G7PeripheralManager) {
        bluetoothManager.delegate = self
        bluetoothManager.adoptAsActive(peripheralManager)
        if let name = peripheralManager.peripheral.name {
            delegateQueue.async {
                self.delegate?.sensorDidConnect(self, name: name)
            }
        }
        beginSession(peripheralManager)
    }

    public func scanForNewSensor() {
        // The pairing code and key belong to the sensor being replaced, not to
        // whatever comes next. Keeping them would make every candidate fail
        // its handshake, so a replacement can only be adopted after pairing.
        mutateCredentials { credentials in
            credentials.sensorID = nil
            credentials.pairingCode = nil
            credentials.sharedKey = nil
            credentials.peripheralIdentifier = nil
        }
        bluetoothManager.setActivePeripheralIdentifier(nil)
        bluetoothManager.disconnect()
        bluetoothManager.forgetPeripheral()
        bluetoothManager.scanForPeripheral()
    }

    public func resumeScanning() {
        bluetoothManager.setActivePeripheralIdentifier(lockedCredentials.value.peripheralIdentifier)
        bluetoothManager.scanForPeripheral()
    }

    public func stopScanning() {
        bluetoothManager.disconnect()
    }

    public var isScanning: Bool {
        return bluetoothManager.isScanning
    }

    public var isConnected: Bool {
        return bluetoothManager.isConnected
    }

    // MARK: - Calibration

    /// Queues a meter glucose for the sensor. It goes out after the reading
    /// reply on the next connection, timestamped with `date` on the sensor's
    /// clock, so it does not matter that the link is down right now.
    public func calibrate(glucose: UInt16, at date: Date) {
        lockedPendingCalibration.value = (glucose, date)
    }

    public var queuedCalibration: (glucose: UInt16, date: Date)? {
        lockedPendingCalibration.value
    }

    /// Drops a calibration that has not gone out yet.
    public func cancelPendingCalibration() {
        lockedPendingCalibration.value = nil
    }

    /// Asks for the sensor's calibration state on the next connection.
    public func requestCalibrationBounds() {
        lockedCalibrationBoundsRequestPending.value = true
    }

    private func sendPendingCalibration(_ peripheral: G7PeripheralManager) {
        guard let activationDate = activationDate else {
            return
        }
        if let calibration = lockedPendingCalibration.value {
            lockedPendingCalibration.value = nil
            let sensorAge = UInt32(max(0, calibration.date.timeIntervalSince(activationDate)))
            let request = G7CalibrateTxMessage(glucose: calibration.glucose, sensorAge: sensorAge).data
            logToDevice("Sending calibration \(calibration.glucose) mg/dL taken at sensor age \(sensorAge)s", type: .connection)
            logSend(request, on: .control)
            do {
                try peripheral.writeValue(request, for: .control, type: .withResponse)
            } catch let error {
                log.error("Error sending calibration: %{public}@", String(describing: error))
                logToDevice("Calibration send failed: \(error)", type: .error)
            }
        }
        if lockedCalibrationBoundsRequestPending.value {
            lockedCalibrationBoundsRequestPending.value = false
            sendCalibrationBoundsRequest(peripheral)
        }
    }

    private func sendCalibrationBoundsRequest(_ peripheral: G7PeripheralManager) {
        let request = Data([G7Opcode.calibrationBounds.rawValue])
        logSend(request, on: .control)
        do {
            try peripheral.writeValue(request, for: .control, type: .withResponse)
        } catch let error {
            log.error("Error requesting calibration bounds: %{public}@", String(describing: error))
        }
    }

    private func handleGlucoseMessage(message: G7GlucoseMessage, peripheralManager: G7PeripheralManager) {
        activationDate = Date().addingTimeInterval(-TimeInterval(message.messageTimestamp))
        let credentials = lockedCredentials.value

        if mode == .direct, credentials.sensorID != nil, isOurSensor(peripheralManager) {
            peripheralManager.perform { peripheral in
                self.sendPendingCalibration(peripheral)
            }
        }

        if backfillRequestPending {
            backfillRequestPending = false
            let latest = latestReadingDate
            peripheralManager.perform { peripheral in
                self.requestBackfillIfNeeded(peripheral, latestReadingDate: latest)
            }
        }

        peripheralManager.perform { (peripheral) in
            self.log.default("Listening for backfill responses")
            // Subscribe to backfill updates
            do {
                try peripheral.listenToCharacteristic(.backfill)
            } catch let error {
                self.log.error("Error trying to enable notifications on backfill characteristic: %{public}@", String(describing: error))
                self.delegateQueue.async {
                    self.delegate?.sensor(self, didError: error)
                }
            }
        }

        if needsVersionInfo, credentials.sensorID != nil, isOurSensor(peripheralManager) {
            peripheralManager.perform { (peripheral) in
                do {
                    self.logSend(Data([G7Opcode.extendedVersionTx.rawValue]), on: .control)
                    try peripheral.requestExtendedVersion()
                } catch let error {
                    self.log.error("Error trying to request extended version: %{public}@", String(describing: error))
                }
            }
        }

        if credentials.sensorID == nil, let name = peripheralManager.peripheral.name, let activationDate = activationDate  {
            delegateQueue.async {
                guard let delegate = self.delegate else {
                    return
                }

                if delegate.sensor(self, didDiscoverNewSensor: name, activatedAt: activationDate) {
                    self.mutateCredentials { credentials in
                        credentials.sensorID = name
                        credentials.peripheralIdentifier = peripheralManager.peripheral.identifier
                    }
                    self.bluetoothManager.setActivePeripheralIdentifier(peripheralManager.peripheral.identifier)
                    self.activationDate = activationDate
                    self.needsVersionInfo = true
                    self.latestReadingDate = activationDate.addingTimeInterval(TimeInterval(message.messageTimestamp))
                    self.delegate?.sensor(self, didRead: message)
                    self.bluetoothManager.stopScanning()
                    if self.needsVersionInfo, self.isOurSensor(peripheralManager) {
                        peripheralManager.perform { (peripheral) in
                            do {
                                self.logSend(Data([G7Opcode.extendedVersionTx.rawValue]), on: .control)
                                try peripheral.requestExtendedVersion()
                            } catch let error {
                                self.log.error("Error trying to request extended version on initial detection: %{public}@", String(describing: error))
                            }
                        }
                    }
                }
            }
        } else if credentials.sensorID != nil {
            latestReadingDate = activationDate?.addingTimeInterval(TimeInterval(message.messageTimestamp))
            delegateQueue.async {
                self.delegate?.sensor(self, didRead: message)
            }
        } else {
            self.log.error("Dropping unhandled glucose message: %{public}@", String(describing: message))
        }
    }

    // MARK: - Direct mode

    /// Runs the handshake and, on success, opens the session.
    private func authenticate(_ peripheralManager: G7PeripheralManager) {
        let credentials = lockedCredentials.value

        guard credentials.sharedKey != nil || credentials.pairingCode != nil else {
            // Without either, a handshake would run the key exchange against
            // whatever Dexcom device is in range and fail every time. Wait for
            // the user to pair instead.
            log.error("Not authenticating: no shared key or pairing code")
            return
        }

        pendingAuth = true

        let authenticator = G7Authenticator(
            pairingCode: credentials.pairingCode,
            storedSharedKey: credentials.sharedKey,
            stepTimeout: credentials.sharedKey == nil
                ? G7Authenticator.pairingStepTimeout
                : G7Authenticator.reconnectStepTimeout,
            displayType: displayType
        )
        authenticator.logHandler = { [weak self] message in
            self?.logToDevice(message, type: .connection)
        }

        authenticator.authenticate(peripheralManager: peripheralManager) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let authResult):
                self.pendingAuth = false
                if authResult.didExchangeKeys {
                    self.mutateCredentials { $0.sharedKey = authResult.sharedKey }
                    self.delegateQueue.async {
                        self.delegate?.sensor(
                            self,
                            didAuthenticateWith: authResult.sharedKey,
                            deviceName: authResult.deviceName
                        )
                    }
                }
                self.beginSession(peripheralManager)
            case .failure(let error):
                self.handleAuthenticationFailure(error)
            }
        }
    }

    /// Subscribes to the session characteristics and asks for a reading right
    /// away, mirroring what the official app does after authenticating. A
    /// sensor only links briefly around each 5-minute reading, so waiting for
    /// an unprompted broadcast can cost a whole cycle.
    private func beginSession(_ peripheralManager: G7PeripheralManager) {
        peripheralManager.perform { peripheral in
            // A handshake can succeed and the sensor still drop the link
            // before this runs (seen after the bond request). Nothing to open
            // then; the reconnect authenticates with the stored key.
            guard peripheral.peripheral.state == .connected else {
                self.logToDevice("Link dropped before the session could open; waiting for the sensor to reconnect", type: .connection)
                return
            }
            do {
                try peripheral.listenToCharacteristic(.control)
                try peripheral.listenToCharacteristic(.backfill)
                // Ask for the reading first and the backfill only once its
                // reply is in: the sensor handles one command at a time, and
                // a backfill request sent on top of a pending GetEgv cost us
                // the reading.
                self.backfillRequestPending = true
                let request = Data([G7Opcode.glucoseTx.rawValue])
                self.logSend(request, on: .control)
                try peripheral.writeValue(request, for: .control, type: .withResponse)
            } catch let error {
                self.log.error("Error opening session: %{public}@", String(describing: error))
                self.delegateQueue.async {
                    self.delegate?.sensor(self, didError: error)
                }
                return
            }
        }
    }

    /// Asks for the readings taken while we were not connected. Nothing else
    /// requests them in direct mode, so without this a gap never fills. The
    /// range starts at the last reading we have, so an outage longer than the
    /// default window is still asked for in full (up to the cap); the sensor
    /// returns what it holds and the manager drops duplicates by timestamp.
    private func requestBackfillIfNeeded(_ peripheral: G7PeripheralManager, latestReadingDate: Date?) {
        guard let activationDate = activationDate else {
            return
        }

        let now = Date()
        let gapStart: Date
        if let latestReadingDate = latestReadingDate {
            gapStart = latestReadingDate
        } else {
            gapStart = now.addingTimeInterval(-G7Sensor.backfillWindow)
        }
        let earliest = max(activationDate, gapStart, now.addingTimeInterval(-G7Sensor.maximumBackfillWindow))
        guard earliest < now else {
            return
        }

        let start = UInt32(earliest.timeIntervalSince(activationDate))
        let end = UInt32(now.timeIntervalSince(activationDate))
        guard start < end else {
            return
        }

        var request = Data([G7Opcode.backfillFinished.rawValue])
        request.append(start.littleEndian)
        request.append(end.littleEndian)

        do {
            log.default("Requesting backfill from %{public}d to %{public}d", start, end)
            logSend(request, on: .control)
            try peripheral.writeValue(request, for: .control, type: .withResponse)
        } catch let error {
            log.error("Error requesting backfill: %{public}@", String(describing: error))
            logToDevice("Backfill request failed: \(error)", type: .error)
        }
    }

    private func handleAuthenticationFailure(_ error: Error) {
        pendingAuth = false
        log.error("Authentication failed: %{public}@", String(describing: error))

        // A stale key is recoverable without the user: drop it, and the next
        // connection runs a full handshake with the pairing code we still
        // hold. Two signals say the key is stale: the sensor's answer to our
        // challenge not matching (caught before we ever send a wrong reply,
        // so the sensor records no rejection), and the sensor saying outright
        // that it has no key for us. Without a code there is nothing to fall
        // back to, so leave the key in place rather than locking the sensor
        // out of reconnecting.
        let keyIsStale: Bool
        switch error {
        case G7AuthenticatorError.challengeMismatch,
             G7AuthenticatorError.rejected(_, .noAppKey):
            keyIsStale = true
        default:
            keyIsStale = false
        }
        if keyIsStale,
           lockedCredentials.value.sharedKey != nil,
           lockedCredentials.value.pairingCode != nil
        {
            log.default("Discarding the stored shared key; the next connection will re-run the key exchange")
            mutateCredentials { $0.sharedKey = nil }
            delegateQueue.async {
                self.delegate?.sensorDidInvalidateSharedKey(self)
            }
            return
        }

        delegateQueue.async {
            self.delegate?.sensor(self, didError: error)
        }
    }

    // MARK: - BluetoothManagerDelegate

    func bluetoothManager(_ manager: G7BluetoothManager, readied peripheralManager: G7PeripheralManager) -> Bool {
        var shouldStopScanning = false;
        let credentials = lockedCredentials.value

        // Ours by identifier once paired, even before the first reading has
        // supplied a sensor ID; otherwise the hand-off connection's events
        // went unlogged and its disconnect left the pending flags set.
        if isOurSensor(peripheralManager) {
            shouldStopScanning = true
            let name = credentials.sensorID ?? peripheralManager.peripheral.name ?? "sensor"
            delegateQueue.async {
                self.delegate?.sensorDidConnect(self, name: name)
            }
        }

        switch mode {
        case .direct:
            authenticate(peripheralManager)

        case .eavesdropping:
            peripheralManager.perform { (peripheral) in
                // .default so this survives into a sysdiagnose: info and debug are
                // memory-only and are not written to the log archive, which makes the
                // auth handshake invisible in field diagnostics.
                self.log.default("Listening for authentication responses for %{public}@", String(describing: peripheralManager.peripheral.name))
                do {
                    try peripheral.listenToCharacteristic(.authentication)
                    self.pendingAuth = true
                } catch let error {
                    self.delegateQueue.async {
                        self.delegate?.sensor(self, didError: error)
                    }
                }
            }
        }
        return shouldStopScanning
    }

    func bluetoothManager(_ manager: G7BluetoothManager, readyingFailed peripheralManager: G7PeripheralManager, with error: Error) {
        delegateQueue.async {
            self.delegate?.sensor(self, didError: error)
        }
    }

    func peripheralDidDisconnect(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, wasRemoteDisconnect: Bool) {
        if isOurSensor(peripheralManager) {

            // Sometimes we do not receive the backfillFinished message before disconnect
            flushBackfillBuffer()

            let suspectedEndOfSession: Bool

            self.log.info("Sensor disconnected: wasRemoteDisconnect:%{public}@", String(describing: wasRemoteDisconnect))
            logToDevice(wasRemoteDisconnect ? "Disconnected by sensor" : "Disconnected by phone", type: .connection)
            // Only meaningful while eavesdropping, where the only reason to see
            // an authenticated session appear is the Dexcom app creating one.
            // In direct mode we authenticate ourselves and the sensor drops the
            // link at the end of every reading cycle, so this would fire
            // constantly; session end is read from the algorithm state instead.
            if mode == .eavesdropping, pendingAuth, wasRemoteDisconnect {
                suspectedEndOfSession = true // Normal disconnect without auth is likely that G7 app stopped this session
            } else {
                suspectedEndOfSession = false
            }
            pendingAuth = false
            backfillRequestPending = false

            delegateQueue.async {
                self.delegate?.sensorDisconnected(self, suspectedEndOfSession: suspectedEndOfSession)
            }
        }
    }

    func bluetoothManager(_ manager: G7BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) -> PeripheralConnectionCommand {

        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name

        guard let name = name else {
            log.debug("Not connecting to unnamed peripheral: %{public}@", String(describing: peripheral))
            return .ignore
        }

        let credentials = lockedCredentials.value

        // Nothing to pair with yet: no code, no key. Connecting would only
        // take a slot on whatever sensor is nearby.
        if mode == .direct, credentials.pairingCode == nil, credentials.sharedKey == nil, credentials.peripheralIdentifier == nil {
            return .ignore
        }

        // Once paired, only ever the sensor we paired with, and by identifier,
        // never by name: a peripheral retrieved for a reconnect carries the
        // post-connection "Dexcomxx" name, not the advertised "DXCMxx". A
        // sensor admits one display at a time, so connecting to a stranger's
        // sensor would take its slot, and our key would not authenticate
        // there anyway.
        if mode == .direct, let identifier = credentials.peripheralIdentifier {
            guard peripheral.identifier == identifier else {
                return .ignore
            }
            logToDevice("Connecting to \(name)", type: .connection)
            return .makeActive
        }

        guard G7Sensor.isSensorName(name) else {
            log.info("Not connecting to peripheral: %{public}@", name)
            return .ignore
        }

        // If we're following this name or if we're scanning, connect
        if let sensorName = credentials.sensorID, name.suffix(2) == sensorName.suffix(2) {
            logToDevice("Connecting to \(name)", type: .connection)
            return .makeActive
        } else if credentials.sensorID == nil {
            logToDevice("Connecting to \(name) to identify it", type: .connection)
            return .connect
        }

        log.info("Not connecting to peripheral: %{public}@", name)
        return .ignore
    }

    func bluetoothManagerShouldAcceptRestoredPeripherals(_ manager: G7BluetoothManager) -> Bool {
        // A session wants its sensor back after a relaunch.
        return true
    }

    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveControlResponse response: Data) {

        guard response.count > 0 else { return }

        log.default("Received control response: %{public}@", response.hexadecimalString)
        delegateQueue.async {
            self.delegate?.sensor(self, logComms: "control \(response.hexadecimalString)")
        }

        switch G7Opcode(rawValue: response[0]) {
        case .glucoseTx?:
            if let glucoseMessage = G7GlucoseMessage(data: response) {
                handleGlucoseMessage(message: glucoseMessage, peripheralManager: peripheralManager)
            } else {
                delegateQueue.async {
                    self.delegate?.sensor(self, didError: G7SensorError.observationError("Unable to handle glucose control response"))
                }
            }
        case .extendedVersionTx:
            if let extendedVersionMessage = ExtendedVersionMessage(data: response) {
                log.default("Received %{public}@", String(describing: extendedVersionMessage))
                delegateQueue.async {
                    self.delegate?.sensor(self, didReceive: extendedVersionMessage)
                    self.needsVersionInfo = false
                }
                // The serial and firmware come from a second query, asked
                // once here so a session learns them alongside its lifetime.
                peripheralManager.perform { peripheral in
                    let request = Data([G7Opcode.transmitterVersion.rawValue])
                    self.logSend(request, on: .control)
                    do {
                        try peripheral.writeValue(request, for: .control, type: .withResponse)
                    } catch let error {
                        self.log.error("Error requesting transmitter version: %{public}@", String(describing: error))
                    }
                }
            }
        case .transmitterVersion:
            if let transmitterVersionMessage = TransmitterVersionMessage(data: response) {
                log.default("Received %{public}@", String(describing: transmitterVersionMessage))
                delegateQueue.async {
                    self.delegate?.sensor(self, didReceive: transmitterVersionMessage)
                }
            }
        case .calibrate:
            if let message = G7CalibrateRxMessage(data: response) {
                logToDevice("Calibration \(message.accepted ? "accepted" : "refused") by the sensor (status \(message.status))", type: .connection)
                delegateQueue.async {
                    self.delegate?.sensor(self, didReceiveCalibrationResponse: message)
                }
                // Confirm what the sensor made of it while the link is up.
                if message.accepted {
                    peripheralManager.perform { peripheral in
                        self.sendCalibrationBoundsRequest(peripheral)
                    }
                }
            }
        case .calibrationBounds:
            if let bounds = G7CalibrationBoundsMessage(data: response) {
                logToDevice("Calibration state: \(bounds)", type: .connection)
                delegateQueue.async {
                    self.delegate?.sensor(self, didReadCalibrationBounds: bounds)
                }
            } else {
                logToDevice("Calibration state reply not understood: \(response.hexadecimalString)", type: .error)
            }
        case .backfillFinished:
            // The acknowledgement arrives after the records, so it doubles as
            // the end-of-stream marker.
            flushBackfillBuffer()
        default:
            break
        }
    }

    func flushBackfillBuffer() {
        if backfillBuffer.count > 0 {
            let backfill = backfillBuffer
            self.backfillBuffer = []
            // The next backfill request starts after the newest record we
            // have, whichever path delivered it.
            if let activationDate = activationDate, let newest = backfill.map({ $0.timestamp }).max() {
                let newestDate = activationDate.addingTimeInterval(TimeInterval(newest))
                if newestDate > (latestReadingDate ?? .distantPast) {
                    latestReadingDate = newestDate
                }
            }
            delegateQueue.async {
                self.delegate?.sensor(self, didReadBackfill: backfill)
            }
        }
    }

    func bluetoothManager(_ manager: G7BluetoothManager, didReceiveBackfillResponse response: Data) {

        log.debug("Received backfill response: %{public}@", response.hexadecimalString)
        logToDevice("backfill \(response.hexadecimalString)", type: .receive)

        // Records are 9 bytes each. A G7 packs two to a notification; the
        // ONE+ (and the Dexcom app's own backfill, which eavesdropping
        // overhears) sends one. Anything else is not a record frame.
        guard response.count % 9 == 0 else {
            logToDevice("Backfill frame of unexpected length \(response.count) ignored", type: .error)
            return
        }

        for offset in stride(from: 0, to: response.count, by: 9) {
            if let msg = G7BackfillMessage(data: response.subdata(in: offset..<(offset + 9))) {
                backfillBuffer.append(msg)
            }
        }
    }

    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveAuthenticationResponse response: Data) {

        // Direct mode drives its own handshake and collects these through the
        // authenticator's handler; anything reaching here is stray.
        guard mode == .eavesdropping else {
            log.default("Ignoring unsolicited authentication response: %{public}@", response.hexadecimalString)
            return
        }

        delegateQueue.async {
            self.delegate?.sensor(self, logComms: "auth \(response.hexadecimalString)")
        }

        if let message = AuthChallengeRxMessage(data: response), message.isBonded, message.isAuthenticated {
            log.default("Observed authenticated session. enabling notifications for control characteristic.")
            pendingAuth = false
            peripheralManager.perform { (peripheral) in
                do {
                    try peripheral.listenToCharacteristic(.control)
                } catch let error {
                    self.log.error("Error trying to enable notifications on control characteristic: %{public}@", String(describing: error))
                    self.delegateQueue.async {
                        self.delegate?.sensor(self, didError: error)
                    }
                }
            }
        } else {
            log.default("Ignoring authentication response: %{public}@", response.hexadecimalString)
        }
    }

    func bluetoothManagerScanningStatusDidChange(_ manager: G7BluetoothManager) {
        // Called on the manager's queue; `isScanning` syncs onto that queue,
        // so it has to be read from somewhere else.
        self.delegateQueue.async {
            self.delegate?.sensor(self, log: manager.isScanning ? "Scanning for sensor" : "Stopped scanning", type: .connection)
            self.delegate?.sensorConnectionStatusDidUpdate(self)
        }
    }
}


// MARK: - Helpers
fileprivate extension G7PeripheralManager {

    func listenToCharacteristic(_ characteristic: CGMServiceCharacteristicUUID) throws {
        do {
            try setNotifyValue(true, for: characteristic)
        } catch let error {
            throw G7SensorError.controlError("Error enabling notification for \(characteristic): \(error)")
        }
    }
}
