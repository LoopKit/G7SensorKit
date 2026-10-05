//
//  G7BluetoothManager.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 11/11/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//
//  Active-peripheral tracking, the powered-on recheck and central recreation
//  are derived from DexKit by Erik Tolboom
//  (https://github.com/nightscout/DexKit).
//

import CoreBluetooth
import Foundation
import os.log


enum PeripheralConnectionCommand {
    case connect
    case makeActive
    case ignore
}

protocol G7BluetoothManagerDelegate: AnyObject {
    /// A signal-strength reading for a connected peripheral, requested with `readRSSI()`.
    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReadRSSI rssi: NSNumber, error: Error?)


    /**
     Tells the delegate that the bluetooth manager has finished connecting to and discovering all required services of its peripheral

     - parameter manager: The bluetooth manager
     - parameter peripheralManager: The peripheral manager
     - parameter error:   An error describing why bluetooth setup failed

     - returns: True if scanning should stop
     */
    func bluetoothManager(_ manager: G7BluetoothManager, readied peripheralManager: G7PeripheralManager) -> Bool

    /**
     Tells the delegate that the bluetooth manager encountered an error while connecting to and discovering required services of a peripheral

     - parameter manager: The bluetooth manager
     - parameter peripheralManager: The peripheral manager
     - parameter error:   An error describing why bluetooth setup failed
     */
    func bluetoothManager(_ manager: G7BluetoothManager, readyingFailed peripheralManager: G7PeripheralManager, with error: Error)

    /**
     Asks the delegate if the discovered or restored peripheral is active or should be connected to

     - parameter manager:    The bluetooth manager
     - parameter peripheral: The found peripheral

     - returns: PeripheralConnectionCommand indicating what should be done with this peripheral
     */
    func bluetoothManager(_ manager: G7BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) -> PeripheralConnectionCommand

    /**
     Asks the delegate whether peripherals restored by CoreBluetooth's state
     restoration should be adopted.

     A session says yes: that is how it resumes its own sensor after a relaunch.
     A pairing run says no, because a stale restored peripheral would be treated
     as a candidate and crowd out the sensor actually being paired.
     */
    func bluetoothManagerShouldAcceptRestoredPeripherals(_ manager: G7BluetoothManager) -> Bool

    /// Informs the delegate that the bluetooth manager received new data in the control characteristic
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    ///   - peripheralManager: The peripheral manager
    ///   - response: The data received on the control characteristic
    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveControlResponse response: Data)

    /// Informs the delegate that the bluetooth manager received new data in the backfill characteristic
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    ///   - response: The data received on the backfill characteristic
    func bluetoothManager(_ manager: G7BluetoothManager, didReceiveBackfillResponse response: Data)

    /// Informs the delegate that the bluetooth manager received new data in the authentication characteristic
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    ///   - peripheralManager: The peripheral manager
    ///   - response: The data received on the authentication characteristic
    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveAuthenticationResponse response: Data)

    /// Informs the delegate that the bluetooth manager started or stopped scanning
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    func bluetoothManagerScanningStatusDidChange(_ manager: G7BluetoothManager)

    /// Informs the delegate that a peripheral disconnected
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    func peripheralDidDisconnect(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, wasRemoteDisconnect: Bool)

    /// One line for the host's device log (OmnipodKit's omnipodLogDeviceEvent shape).
    func bluetoothManager(_ manager: G7BluetoothManager, logEvent line: String)

    /// Whether a connection could be authenticated (direct: a pairing code or stored key;
    /// eavesdropping: always).
    func bluetoothManagerCanAuthenticate(_ manager: G7BluetoothManager) -> Bool

    /// A peripheral was adopted as the sensor (nil when one was let go of).
    func bluetoothManager(_ manager: G7BluetoothManager, didAdoptPeripheral identifier: UUID?)

    /// `needsCodeForSensor` or `isSearchingForSensor` changed.
    func bluetoothManagerStatusDidChange(_ manager: G7BluetoothManager)
}

extension G7BluetoothManagerDelegate {
    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReadRSSI rssi: NSNumber, error: Error?) {}
    func bluetoothManager(_ manager: G7BluetoothManager, logEvent line: String) {}
    func bluetoothManagerCanAuthenticate(_ manager: G7BluetoothManager) -> Bool { true }
    func bluetoothManager(_ manager: G7BluetoothManager, didAdoptPeripheral identifier: UUID?) {}
    func bluetoothManagerStatusDidChange(_ manager: G7BluetoothManager) {}
}

/// Takes over acquisition where a platform cannot use the stock steps (watchOS: the app sleeps
/// between readings and its scanning is rationed). Called on the manager's queue.
protocol G7AcquisitionArm: AnyObject {
    /// In place of the stock retrieve-or-scan.
    func scan()
    /// In place of the stock connect to an adopted sensor.
    func found(_ peripheral: CBPeripheral)
    func connected(_ peripheral: CBPeripheral)
    /// True when the arm owns what happens next; false runs the stock rescan.
    func disconnected(_ peripheral: CBPeripheral, error: Error?) -> Bool
    func failedToConnect(_ peripheral: CBPeripheral, error: Error?) -> Bool
    func radioDown()
    /// A peripheral handed back by state restoration, after the stock adoption.
    func restored(_ peripheral: CBPeripheral)
    /// A reading's own sensor timestamp.
    func noteReading(at timestamp: Date)
    /// Any wake: put acquisition right if a lost callback left nothing standing.
    func recheck()
}

class G7BluetoothManager: NSObject {

    weak var delegate: G7BluetoothManagerDelegate?

    private let log = OSLog(category: "G7BluetoothManager")

    /// Isolated to `managerQueue`
    var centralManager: CBCentralManager! = nil

    /// Whether the radio is usable: off, unauthorized, or on. Readable from
    /// any queue; changes are announced through
    /// `bluetoothManagerScanningStatusDidChange`.
    var centralState: CBManagerState {
        centralManager?.state ?? .unknown
    }

    /// Isolated to `managerQueue`
    var activePeripheral: CBPeripheral? {
        get {
            return activePeripheralManager?.peripheral
        }
    }

    /// Isolated to `managerQueue`
    var managedPeripherals: [UUID:G7PeripheralManager] = [:]

    /// The platform's acquisition arm, or nil for the stock steps. Set once in init, before the
    /// central can call back.
    private(set) var acquisitionArm: G7AcquisitionArm?

    private let lockedNeedsCodeForSensor = Locked<String?>(nil)
    private let lockedIsSearchingForSensor = Locked(false)

    /// The sensor a direct connection would reach without a pairing code or key; nil once one exists.
    var needsCodeForSensor: String? { lockedNeedsCodeForSensor.value }

    /// Scanning for a sensor this controller has never connected to.
    var isSearchingForSensor: Bool { lockedIsSearchingForSensor.value }

    func setNeedsCodeForSensor(_ name: String?) {
        guard lockedNeedsCodeForSensor.value != name else { return }
        lockedNeedsCodeForSensor.value = name
        delegate?.bluetoothManagerStatusDidChange(self)
    }

    func setIsSearchingForSensor(_ searching: Bool) {
        guard lockedIsSearchingForSensor.value != searching else { return }
        lockedIsSearchingForSensor.value = searching
        delegate?.bluetoothManagerStatusDidChange(self)
    }

    var activePeripheralIdentifier: UUID? {
        get {
            return lockedPeripheralIdentifier.value
        }
    }
    private let lockedPeripheralIdentifier: Locked<UUID?> = Locked(nil)

    /// Targets a known peripheral directly, so a relaunch can retrieve it by
    /// identifier instead of waiting for its next advertisement. Passing nil
    /// reopens the search to any sensor in range.
    func setActivePeripheralIdentifier(_ identifier: UUID?) {
        lockedPeripheralIdentifier.value = identifier
    }

    /// Isolated to `managerQueue`
    var activePeripheralManager: G7PeripheralManager? {
        didSet {
            oldValue?.delegate = nil
            lockedPeripheralIdentifier.value = activePeripheralManager?.peripheral.identifier
            let identifier = activePeripheralManager?.peripheral.identifier
            if identifier != oldValue?.peripheral.identifier {
                delegate?.bluetoothManager(self, didAdoptPeripheral: identifier)
            }
        }
    }

    // MARK: - Synchronization

    let managerQueue = DispatchQueue(label: "com.loudnate.CGMBLEKit.bluetoothManagerQueue", qos: .unspecified)

    /// Whether a `.poweredOn` recheck is already pending. Confined to `managerQueue`.
    private var poweredOnRecheckScheduled = false

    /// Consecutive rechecks that still saw a non-`.poweredOn` state, and how
    /// often we have rebuilt the central because of it. Confined to `managerQueue`.
    private var poweredOnRecheckCount = 0
    private var centralRecreationCount = 0

    /// How long to tolerate a stuck state before rebuilding the central.
    private static let poweredOnRecheckInterval: TimeInterval = 3
    private static let poweredOnRechecksBeforeRecreating = 10
    private static let maximumCentralRecreations = 5

    /// There is exactly one of these per session, and a pairing run borrows
    /// it rather than building a second: only one central per app may claim
    /// the restore identifier, and sharing the central is what lets the
    /// session adopt the connection pairing just authenticated instead of
    /// dropping it and waiting for the sensor's next advertisement.
    override init() {
        super.init()

        managerQueue.sync {
            #if os(watchOS)
            self.acquisitionArm = G7WatchAcquisition(manager: self)
            #else
            self.acquisitionArm = nil
            #endif
            self.centralManager = self.makeCentralManager(queue: self.managerQueue)
        }
    }

    /// Factory seam so tests can substitute a central manager without the state
    /// restoration option, which raises an exception outside an app with the
    /// bluetooth-central background mode.
    func makeCentralManager(queue: DispatchQueue) -> CBCentralManager {
        return CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.loudnate.CGMBLEKit"])
    }

    // MARK: - Actions

    // Fire-and-forget onto the manager queue, which keeps callers' order: a synchronous hop from
    // the main thread can wait behind a multi-second handshake and trip the system watchdog.
    func scanForPeripheral() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.async {
            self.managerQueue_scanForPeripheral()
        }
    }

    /// Re-derives the watch's acquisition from the central's own state on a wake; nothing on the phone.
    func recheckAcquisition() {
        managerQueue.async {
            guard self.delegate != nil, self.centralManager.state == .poweredOn,
                  (self.activePeripheral?.state ?? .disconnected) != .connected else { return }
            self.acquisitionArm?.recheck()
        }
    }

    func forgetPeripheral() {
        managerQueue.async {
            self.activePeripheralManager = nil
        }
    }

    func stopScanning() {
        managerQueue.async {
            self.managerQueue_stopScanning()
        }
    }

    func managerQueue_stopScanning() {
        if centralManager.isScanning {
            log.default("Stopping scan")
            centralManager.stopScan()
            delegate?.bluetoothManagerScanningStatusDidChange(self)
        }
    }

    func disconnect() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        managerQueue.async { self.managerQueue_disconnect() }
    }

    private func managerQueue_disconnect() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        if centralManager.isScanning {
            log.default("Stopping scan on disconnect")
            centralManager.stopScan()
            delegate?.bluetoothManagerScanningStatusDidChange(self)
        }

        if let peripheral = activePeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    /// A reading's own sensor timestamp, for the acquisition arm: each glucose message, and the
    /// saved last reading at launch.
    func noteReading(at readingTimestamp: Date) {
        guard let arm = acquisitionArm else { return }
        managerQueue.async { arm.noteReading(at: readingTimestamp) }
    }

    /// Makes `peripheralManager` the active peripheral, keeping its connection,
    /// and drops every other managed peripheral. This is the hand-off at the
    /// end of pairing: the candidate that authenticated becomes the session's
    /// sensor without a disconnect in between.
    func adoptAsActive(_ peripheralManager: G7PeripheralManager) {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            managerQueue_stopScanning()

            for (identifier, other) in managedPeripherals where other !== peripheralManager {
                centralManager.cancelPeripheralConnection(other.peripheral)
                managedPeripherals.removeValue(forKey: identifier)
            }

            if activePeripheralManager !== peripheralManager {
                activePeripheralManager = peripheralManager
            }
            peripheralManager.delegate = self
            peripheralManager.reclaimPeripheral()
            managedPeripherals[peripheralManager.peripheral.identifier] = peripheralManager
        }
    }

    /// Cancels every managed peripheral's connection, not just the active one.
    /// The pairing run needs this: its candidates are never made active (there
    /// is no sensor ID yet), so `disconnect()` would leave them connected.
    func disconnectAll() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            managerQueue_stopScanning()

            for peripheralManager in managedPeripherals.values {
                centralManager.cancelPeripheralConnection(peripheralManager.peripheral)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        managerQueue.async {
            if self.activePeripheralIdentifier == nil {
                self.log.default("Discovered peripheral from connectionEventDidOccur %{public}@", peripheral.identifier.uuidString)
                self.handleDiscoveredPeripheral(peripheral)
            }
        }
    }

    private func managerQueue_scanForPeripheral() {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        // `didDisconnectPeripheral` always rescans, which keeps us alive for a
        // couple of seconds past release. A pairing run that has finished must
        // not start scanning again in that window: the sensor it just paired
        // admits one display, and the session manager is claiming it.
        guard delegate != nil else {
            return
        }

        guard centralManager.state == .poweredOn else {
            schedulePoweredOnRecheck()
            return
        }

        poweredOnRecheckCount = 0

        let currentState = activePeripheral?.state ?? .disconnected
        guard currentState != .connected else {
            return
        }

        if let arm = acquisitionArm {
            arm.scan()
            return
        }

        if let peripheralID = activePeripheralIdentifier, let peripheral = centralManager.retrievePeripherals(withIdentifiers: [peripheralID]).first {
            log.default("Retrieved peripheral %{public}@", peripheral.identifier.uuidString)
            handleDiscoveredPeripheral(peripheral)
        } else {
            for peripheral in centralManager.retrieveConnectedPeripherals(withServices: [
                SensorServiceUUID.advertisement.cbUUID,
                SensorServiceUUID.cgmService.cbUUID
            ]) {
                log.default("Found system-connected peripheral: %{public}@", peripheral.identifier.uuidString)
                handleDiscoveredPeripheral(peripheral)
            }
        }

        if activePeripheral == nil {
            log.default("Scanning for peripherals and listening for connection events")

            centralManager.registerForConnectionEvents(options: [CBConnectionEventMatchingOption.serviceUUIDs: [
                SensorServiceUUID.advertisement.cbUUID,
                SensorServiceUUID.cgmService.cbUUID
            ]])

            centralManager.scanForPeripherals(withServices: [
                    SensorServiceUUID.advertisement.cbUUID
                ],
                options: nil
            )
            delegate?.bluetoothManagerScanningStatusDidChange(self)
        }
    }

    /**

     Persistent connections don't seem to work with the transmitter shutoff: The OS won't re-wake the
     app unless it's scanning.

     The sleep gives the transmitter time to shut down, but keeps the app running.

     */
    /// CoreBluetooth lies about its state at creation: a central built while
    /// another is being torn down can report `.unknown` or even `.unsupported`
    /// and then never send a corrective `didUpdateState`, leaving the manager
    /// permanently convinced Bluetooth is unavailable. Poll our way out, and
    /// rebuild the central if the state stays stuck.
    private func schedulePoweredOnRecheck() {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        guard !poweredOnRecheckScheduled, delegate != nil else {
            return
        }
        poweredOnRecheckScheduled = true

        managerQueue.asyncAfter(deadline: .now() + G7BluetoothManager.poweredOnRecheckInterval) { [weak self] in
            guard let self = self else { return }
            self.poweredOnRecheckScheduled = false

            guard self.delegate != nil else {
                return
            }
            guard self.centralManager.state != .poweredOn else {
                self.poweredOnRecheckCount = 0
                self.managerQueue_scanForPeripheral()
                return
            }

            self.poweredOnRecheckCount += 1
            self.log.default(
                "Bluetooth still %{public}@ after %{public}d rechecks",
                String(describing: self.centralManager.state.rawValue),
                self.poweredOnRecheckCount
            )

            let isStuckState = self.centralManager.state == .unknown || self.centralManager.state == .unsupported
            if isStuckState,
               self.poweredOnRecheckCount >= G7BluetoothManager.poweredOnRechecksBeforeRecreating,
               self.centralRecreationCount < G7BluetoothManager.maximumCentralRecreations,
               self.managedPeripherals.isEmpty
            {
                self.log.error("Recreating central manager stuck at %{public}@", String(describing: self.centralManager.state.rawValue))
                self.centralRecreationCount += 1
                self.poweredOnRecheckCount = 0
                self.centralManager.delegate = nil
                self.centralManager = self.makeCentralManager(queue: self.managerQueue)
            }

            self.schedulePoweredOnRecheck()
        }
    }

    fileprivate func scanAfterDelay() {
        DispatchQueue.global(qos: .utility).async {
            Thread.sleep(forTimeInterval: 2)

            self.scanForPeripheral()
        }
    }

    // MARK: - Accessors

    var isScanning: Bool {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        var isScanning = false
        managerQueue.sync {
            isScanning = centralManager.isScanning
        }
        return isScanning
    }

    var isConnected: Bool {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        var isConnected = false
        managerQueue.sync {
            isConnected = activePeripheral?.state == .connected
        }
        return isConnected
    }

    /// The manager already attached to this peripheral, if there is one. A
    /// candidate dropped from `managedPeripherals` on disconnect is still the
    /// peripheral's delegate, and may still have a handshake running; a
    /// second manager would take the delegate role from it, and its commands
    /// would never hear back.
    private func makeOrReusePeripheralManager(_ peripheral: CBPeripheral) -> G7PeripheralManager {
        if let existing = peripheral.delegate as? G7PeripheralManager {
            return existing
        }
        return G7PeripheralManager(peripheral: peripheral, configuration: .dexcomG7, centralManager: centralManager)
    }

    func handleDiscoveredPeripheral(_ peripheral: CBPeripheral, advertisementData: [String: Any] = [:], rssi: NSNumber = 127) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        if let delegate = delegate {
            switch delegate.bluetoothManager(self, shouldConnectPeripheral: peripheral, advertisementData: advertisementData, rssi: rssi) {
            case .makeActive:
                log.default("Making peripheral active: %{public}@", peripheral.identifier.uuidString)

                if let peripheralManager = activePeripheralManager {
                    if peripheralManager.peripheral.identifier != peripheral.identifier {
                        delegate.bluetoothManager(self, didAdoptPeripheral: peripheral.identifier)
                    }
                    peripheralManager.peripheral = peripheral
                } else {
                    activePeripheralManager = makeOrReusePeripheralManager(peripheral)
                    activePeripheralManager?.delegate = self
                }
                self.managedPeripherals[peripheral.identifier] = activePeripheralManager
                if let arm = acquisitionArm {
                    arm.found(peripheral)
                } else {
                    self.centralManager.connect(peripheral)
                }

            case .connect:
                // Pairing hears repeat advertisements from the same candidate;
                // building a second manager for one peripheral leaves the first
                // as an orphaned delegate and loses handshake traffic.
                if let existingManager = self.managedPeripherals[peripheral.identifier] {
                    existingManager.peripheral = peripheral
                    if peripheral.state != .connected, peripheral.state != .connecting {
                        log.default("Reconnecting to peripheral: %{public}@", peripheral.identifier.uuidString)
                        self.centralManager.connect(peripheral)
                    }
                } else {
                    log.default("Connecting to peripheral: %{public}@", peripheral.identifier.uuidString)
                    let peripheralManager = makeOrReusePeripheralManager(peripheral)
                    peripheralManager.delegate = self
                    self.managedPeripherals[peripheral.identifier] = peripheralManager
                    self.centralManager.connect(peripheral)
                }
            case .ignore:
                break
            }
        }
    }

    override var debugDescription: String {
        return [
            "## BluetoothManager",
            activePeripheralManager.map(String.init(reflecting:)) ?? "No peripheral",
        ].joined(separator: "\n")
    }
}


extension G7BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        activePeripheralManager?.centralManagerDidUpdateState(central)
        log.default("%{public}@: %{public}@", #function, String(describing: central.state.rawValue))

        switch central.state {
        case .poweredOn:
            managerQueue_scanForPeripheral()
        case .resetting, .poweredOff, .unauthorized, .unknown, .unsupported:
            fallthrough
        @unknown default:
            acquisitionArm?.radioDown()
            if central.isScanning {
                log.default("Stopping scan on central not powered on")
                central.stopScan()
            }
        }
        delegate?.bluetoothManagerScanningStatusDidChange(self)
    }

    // A daemon-held connect relaunches the app for the link; this is where the relaunch hands it back.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        guard delegate?.bluetoothManagerShouldAcceptRestoredPeripherals(self) ?? true else {
            log.default("Ignoring restored peripherals: delegate is not accepting them")
            return
        }

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            let line = "RESTORED by the system — relaunched for Bluetooth with \(peripherals.count) peripheral(s): "
                + peripherals.map { "\($0.name ?? "unnamed") state=\($0.state.rawValue)" }.joined(separator: ", ")
            log.default("%{public}@", line)
            delegate?.bluetoothManager(self, logEvent: line)
            for peripheral in peripherals {
                log.default("Restoring peripheral from state: %{public}@", peripheral.identifier.uuidString)
                handleDiscoveredPeripheral(peripheral)
                acquisitionArm?.restored(peripheral)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("%{public}@: %{public}@, data = %{public}@", #function, peripheral, String(describing: advertisementData))

        managerQueue.async {
            self.handleDiscoveredPeripheral(peripheral, advertisementData: advertisementData, rssi: RSSI)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        acquisitionArm?.connected(peripheral)

        log.default("%{public}@: %{public}@", #function, peripheral)

        if let peripheralManager = managedPeripherals[peripheral.identifier] {
            peripheralManager.centralManager(central, didConnect: peripheral)

            if let delegate = delegate, case .poweredOn = centralManager.state, case .connected = peripheral.state {
                if delegate.bluetoothManager(self, readied: peripheralManager) {
                    managerQueue_stopScanning()
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        log.default("%{public}@: %{public}@", #function, peripheral)
        // Ignore errors indicating the peripheral disconnected remotely, as that's expected behavior
        if let error = error as NSError?, CBError(_nsError: error).code != .peripheralDisconnected {
            log.error("%{public}@: %{public}@", #function, error)
            if let peripheralManager = activePeripheralManager {
                self.delegate?.bluetoothManager(self, readyingFailed: peripheralManager, with: error)
            }
        }

        if let peripheralManager = managedPeripherals[peripheral.identifier] {
            let remoteDisconnect: Bool
            if let error = error as NSError?, CBError(_nsError: error).code == .peripheralDisconnected {
                remoteDisconnect = true
            } else {
                remoteDisconnect = false
            }
            self.delegate?.peripheralDidDisconnect(self, peripheralManager: peripheralManager, wasRemoteDisconnect: remoteDisconnect)
        }

        if peripheral != activePeripheral {
            managedPeripherals.removeValue(forKey: peripheral.identifier)
        }

        if acquisitionArm?.disconnected(peripheral, error: error) == true { return }
        scanAfterDelay()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.error("%{public}@: %{public}@", #function, String(describing: error))
        if let error = error, let peripheralManager = activePeripheralManager {
            self.delegate?.bluetoothManager(self, readyingFailed: peripheralManager, with: error)
        }

        if acquisitionArm?.failedToConnect(peripheral, error: error) == true { return }

        if peripheral != activePeripheral {
            managedPeripherals.removeValue(forKey: peripheral.identifier)
        }

        scanAfterDelay()
    }
}


extension G7BluetoothManager: G7PeripheralManagerDelegate {
    func peripheralManager(_ manager: G7PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?) {
        delegate?.bluetoothManager(self, peripheralManager: manager, didReadRSSI: RSSI, error: error)
    }

    func peripheralManagerDidUpdateName(_ manager: G7PeripheralManager) {
    }

    func peripheralManagerDidConnect(_ manager: G7PeripheralManager) {
    }

    func completeConfiguration(for manager: G7PeripheralManager) throws {
    }

    func peripheralManager(_ manager: G7PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic) {
        guard let value = characteristic.value else {
            return
        }

        switch CGMServiceCharacteristicUUID(rawValue: characteristic.uuid.uuidString.uppercased()) {
        case .none, .communication?, .certificate?:
            // The certificate characteristic only carries handshake payloads,
            // which the authenticator collects through an installed handler.
            return
        case .control?:
            self.delegate?.bluetoothManager(self, peripheralManager: manager, didReceiveControlResponse: value)
        case .backfill?:
            self.delegate?.bluetoothManager(self, didReceiveBackfillResponse: value)
        case .authentication?:
            self.delegate?.bluetoothManager(self, peripheralManager: manager, didReceiveAuthenticationResponse: value)
        }
    }
}
