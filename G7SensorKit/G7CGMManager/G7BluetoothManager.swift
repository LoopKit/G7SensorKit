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
    func bluetoothManager(_ manager: G7BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral, advertisementData: [String: Any]) -> PeripheralConnectionCommand

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

#if os(watchOS)
    /// One line from the watch acquisition arm for the host's device log (Pete's
    /// omnipodLogDeviceEvent shape): os_log alone never reaches the wrist's file log.
    func bluetoothManager(_ manager: G7BluetoothManager, logEvent line: String)

    /// Whether a connection could be authenticated once it is up: in direct mode, a pairing code
    /// or a stored key for the sensor; while eavesdropping, always. The arm does not lodge a
    /// request it could only watch fail.
    func bluetoothManagerCanAuthenticate(_ manager: G7BluetoothManager) -> Bool
#endif
}

#if os(watchOS)
extension G7BluetoothManagerDelegate {
    /// Optional: only the watch produces these.
    func bluetoothManager(_ manager: G7BluetoothManager, logEvent line: String) {}
    func bluetoothManagerCanAuthenticate(_ manager: G7BluetoothManager) -> Bool { true }
}
#endif

class G7BluetoothManager: NSObject {

    weak var delegate: G7BluetoothManagerDelegate?

    private let log = OSLog(category: "G7BluetoothManager")

    /// Isolated to `managerQueue`
    private var centralManager: CBCentralManager! = nil

    /// Whether the radio is usable: off, unauthorized, or on. Readable from
    /// any queue; changes are announced through
    /// `bluetoothManagerScanningStatusDidChange`.
    var centralState: CBManagerState {
        centralManager?.state ?? .unknown
    }

    /// Isolated to `managerQueue`
    private var activePeripheral: CBPeripheral? {
        get {
            return activePeripheralManager?.peripheral
        }
    }

    /// Isolated to `managerQueue`
    private var managedPeripherals: [UUID:G7PeripheralManager] = [:]

#if os(watchOS)
    // MARK: - Watch acquisition state — managerQueue only (the arm is the extension at the end of this file)

    /// The in-flight handshake; nil between links.
    /// didConnect stamp; the tail clearance counts from here.
    private var linkUpAt: Date?
    /// Exactly one daemon-held request in flight.
    private var lodged = false
    private var lodgedAt: Date?
    /// Consecutive synchronous refusals (Pete: back off, stop after two).
    private var refusals = 0
    /// A hold-then-connect is running (the holdApp arm); its end lodges.
    private var holdPending = false
    /// The one scan pass.
    private var bootstrapPass = false
    private var bootstrapTimer: DispatchSourceTimer?
    /// When the last bootstrap pass started: a silent sensor is scanned for once per three bursts.
    private var lastBootstrapAt: Date?
    /// The last reading's SENSOR timestamp, persisted: the 3-miss test and the grid survive a relaunch.
    private var lastReadingAt: Date? {
        get { (UserDefaults.standard.object(forKey: G7WatchAcquisition.lastReadingKey) as? Double).map { Date(timeIntervalSince1970: $0) } }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970, forKey: G7WatchAcquisition.lastReadingKey) }
    }
    /// The adopted peripheral's CoreBluetooth identifier, persisted: a relaunch re-adopts without a scan.
    private var rememberedPeripheralID: UUID? {
        get { UserDefaults.standard.string(forKey: G7WatchAcquisition.adoptedPeripheralKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: G7WatchAcquisition.adoptedPeripheralKey) }
    }
#endif

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
    private var activePeripheralManager: G7PeripheralManager? {
        didSet {
            oldValue?.delegate = nil
            lockedPeripheralIdentifier.value = activePeripheralManager?.peripheral.identifier
#if os(watchOS)
            rememberedPeripheralID = activePeripheralManager?.peripheral.identifier
#endif
        }
    }

    // MARK: - Synchronization

    private let managerQueue = DispatchQueue(label: "com.loudnate.CGMBLEKit.bluetoothManagerQueue", qos: .unspecified)

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

    // The public actions are fire-and-forget onto the manager queue (FIFO keeps callers'
    // ordering — e.g. disconnect → forget → scan). None of them needs a synchronous result, and
    // a synchronous hop from the main thread is what the 2026-09-12 watchdog kill was made of.
    func scanForPeripheral() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.async {
            self.managerQueue_scanForPeripheral()
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

    private func managerQueue_stopScanning() {
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

    /// A reading arrived (G7Sensor, every glucose message). Watch: stamps the arm's miss clock and
    /// the grid the peteDelay re-lodge aims at — the reading's own sensor timestamp.
    func noteReading(at readingTimestamp: Date) {
#if os(watchOS)
        managerQueue.async { self.lastReadingAt = readingTimestamp }
#endif
    }

#if os(watchOS)
    /// The user's "Reconnect sensor": drop the link or the lodged request and run ONE bootstrap
    /// pass. Identity kept.
    func reconnect() {
        managerQueue.async { [self] in
            watchLog("USER RECONNECT — dropping the link/request; one bootstrap pass")
            lodged = false; lodgedAt = nil
            lastBootstrapAt = nil
            managerQueue_startBootstrapPass(reason: "user reconnect")     // armed FIRST so the cancel's close does not re-lodge
            if let p = activePeripheral, p.state != .disconnected { centralManager.cancelPeripheralConnection(p) }
        }
    }

    /// The phone reported a NEW sensor we hold a code for (G7CGMManager.receivePairingCode):
    /// forget the old one, find the new one.
    func reacquireForNewSensor() {
        managerQueue.async { [self] in
            if let p = activePeripheral, p.state != .disconnected { centralManager.cancelPeripheralConnection(p) }
            activePeripheralManager = nil            // clears the remembered id too (didSet)
            lodged = false; lodgedAt = nil; linkUpAt = nil
            lastBootstrapAt = nil
            managerQueue_startBootstrapPass(reason: "new sensor from the phone")
        }
    }
#endif

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

#if os(watchOS)
        managerQueue_watchArm()                      // one design on the watch; the stock scan below is the phone's
#else
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
#endif
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

    // WATCHDOG KILL 2026-09-12 08:42 (0x8BADF00D, 10 s): the diagnostics page read these on the
    // MAIN thread inside a SwiftUI update, `managerQueue.sync` waited behind a direct-auth
    // handshake (blocking writes, up to 8 s each), and the BLE queue was itself waiting on
    // SwiftUI's lock — a lock inversion. The UI must never block on this queue: wait at most
    // 50 ms, otherwise hand back the last value the queue reported.
    private let readCacheLock = NSLock()
    private var readCache: [String: Bool] = [:]

    private func boundedRead(_ key: String, _ compute: @escaping () -> Bool) -> Bool {
        let done = DispatchSemaphore(value: 0)
        managerQueue.async { [weak self] in
            guard let self = self else { done.signal(); return }
            let value = compute()
            self.readCacheLock.lock(); self.readCache[key] = value; self.readCacheLock.unlock()
            done.signal()
        }
#if os(watchOS)
        _ = done.wait(timeout: .now() + 0.05)   // 2026-09-12 lock-inversion watchdog kill
#else
        done.wait()                             // stock semantics: a synchronous read of the queue's answer
#endif
        readCacheLock.lock(); defer { readCacheLock.unlock() }
        return readCache[key] ?? false
    }

    var isScanning: Bool {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        return boundedRead("scanning") { [unowned self] in self.centralManager.isScanning }
    }

    var isConnected: Bool {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        return boundedRead("connected") { [unowned self] in self.activePeripheral?.state == .connected }
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

    private func handleDiscoveredPeripheral(_ peripheral: CBPeripheral, advertisementData: [String: Any] = [:]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

#if os(watchOS)
        // #101 churn fix (2026-08-10 23:31:52-59): a discovery during a pending connect issued
        // ANOTHER connect() and minted a fresh G7PeripheralManager per event (~10/s). A pending
        // connect is already doing everything a duplicate would; skip it.
        if peripheral.state == .connecting, managedPeripherals[peripheral.identifier] != nil {
            return
        }
#endif

        if let delegate = delegate {
            switch delegate.bluetoothManager(self, shouldConnectPeripheral: peripheral, advertisementData: advertisementData) {
            case .makeActive:
                log.default("Making peripheral active: %{public}@", peripheral.identifier.uuidString)

                if let peripheralManager = activePeripheralManager {
                    peripheralManager.peripheral = peripheral
                } else {
                    activePeripheralManager = makeOrReusePeripheralManager(peripheral)
                    activePeripheralManager?.delegate = self
                }
                self.managedPeripherals[peripheral.identifier] = activePeripheralManager
#if os(watchOS)
                managerQueue_lodge(peripheral, startDelay: nil, why: "adopted on discovery")   // handles .connecting/.connected/no-code
#else
                self.centralManager.connect(peripheral)
#endif

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
#if os(watchOS)
            // The daemon drops every request with the radio: a request we still believed lodged
            // would block the next lodge until the 3-miss test. Start clean at the next poweredOn.
            lodged = false; lodgedAt = nil; linkUpAt = nil
            // Same for a scan: the next poweredOn has to be free to start one.
            bootstrapPass = false
            bootstrapTimer?.cancel(); bootstrapTimer = nil
#endif
            if central.isScanning {
                log.default("Stopping scan on central not powered on")
                central.stopScan()
            }
        }
        delegate?.bluetoothManagerScanningStatusDidChange(self)
    }

    // The watch central always opts into restoration: a daemon-held connect relaunches us for the
    // link, and this is where the relaunch hands it back.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        guard delegate?.bluetoothManagerShouldAcceptRestoredPeripherals(self) ?? true else {
            log.default("Ignoring restored peripherals: delegate is not accepting them")
            return
        }

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
#if os(watchOS)
            watchLog("RESTORED by the system — relaunched for Bluetooth with \(peripherals.count) peripheral(s): "
                     + peripherals.map { "\($0.name ?? "unnamed") state=\($0.state.rawValue)" }.joined(separator: ", "))
#endif
            for peripheral in peripherals {
                log.default("Restoring peripheral from state: %{public}@", peripheral.identifier.uuidString)
                handleDiscoveredPeripheral(peripheral)
#if os(watchOS)
                // An already-connected peripheral gets no second didConnect: run that path now so
                // the handshake starts on the link the system brought us back for.
                if peripheral.state == .connected { self.centralManager(central, didConnect: peripheral) }
#endif
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("%{public}@: %{public}@, data = %{public}@", #function, peripheral, String(describing: advertisementData))

        managerQueue.async {
            self.handleDiscoveredPeripheral(peripheral, advertisementData: advertisementData)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
#if os(watchOS)
        managerQueue_watchLinkUp(peripheral)
#endif

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

#if os(watchOS)
        if managerQueue_watchDidDisconnect(peripheral, error: error) { return }
#endif
        scanAfterDelay()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.error("%{public}@: %{public}@", #function, String(describing: error))
        if let error = error, let peripheralManager = activePeripheralManager {
            self.delegate?.bluetoothManager(self, readyingFailed: peripheralManager, with: error)
        }

#if os(watchOS)
        if managerQueue_watchDidFailToConnect(peripheral, error: error) { return }
#endif

        if peripheral != activePeripheral {
            managedPeripherals.removeValue(forKey: peripheral.identifier)
        }

        scanAfterDelay()
    }
}


extension G7BluetoothManager: G7PeripheralManagerDelegate {
    func peripheralManager(_ manager: G7PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?) {

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

#if os(watchOS)
// MARK: - The watch acquisition arm
//
// Shape: Pete's issueDelayedConnectProbe (OmnipodKit/Bluetooth/BluetoothManager.swift): one
// daemon-held connect, one in flight (`lodged` ≙ delayedProbeInFlight), a synchronously refused
// connect backs off heartbeatFailureBackoffSeconds and re-checks state, and the central opts into
// restoration so watchOS relaunches us for the link. Deviations, each tied to a measurement:
//  • how the next request reaches the daemon after each reading is the Diagnostics page's
//    Re-lodge toggle (G7WatchAcquisition.relodge). `peteDelay` hands the daemon a start delay
//    aimed at the next reading — 298 − (now − bg_timestamp), his formula (measured 1 in 4: the
//    daemon services a delayed connect 0.3–269 s late). `holdApp` holds the process 35 s after
//    link-up and then lodges a plain connect (33 in 33, at 35 s of held runtime per cycle — the
//    one thing his design forbids). The sensor closes the link ~3.5 s after the 0x4E read and
//    advertises 20–24 s after that (sniffer); a request the daemon holds past +35 s never
//    reconnects into that tail. Reconnecting into it produced reason-762 failures, five of which
//    park bluetoothd's −70 dBm floor on the SHARED accept-list entry.
//  • EVERY close of the adopted sensor — read done or not, handshake failed or not — re-lodges
//    through the selected arm. A plain connect straight after a failure reconnected into the
//    tail and produced a same-burst failure storm (58 of 77 handshakes, 2026-09-16 03:50–07:00);
//    only the bootstrap pass and the refusal back-off ever issue one.
//  • the handshake runs under performExpiringActivity: a relaunched app gets ~1–2 s, the full
//    J-PAKE needs ~7 s (the fast path ~1.2 s).
//  • two synchronous refusals stop re-lodging until the next real wake: the fork measured
//    26,558 spin iterations in one wake before it had a guard.
//  • with authentication OFF (ride the Dexcom watch app) the arm still lodges, but no handshake
//    starts on connect: the stock passive observer reads whatever Dexcom's app authenticates.
extension G7BluetoothManager {

    fileprivate func watchLog(_ line: String) {
        log.default("[g7-watch] %{public}@", line)
        delegate?.bluetoothManager(self, logEvent: line)      // → G7Sensor → G7CGMManager.logDeviceCommunication (Pete's omnipodLogDeviceEvent shape)
    }

    /// The stock scan entry on the watch. Runs at poweredOn, on G7Sensor.resumeScanning (the loop's
    /// fetch, the foreground, a pairing code arriving), after a forget, after the bootstrap cap. A
    /// real wake resets Pete's stop-after-two.
    fileprivate func managerQueue_watchArm() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard centralManager.state == .poweredOn else { return }
        refusals = 0
        guard let id = activePeripheralIdentifier ?? rememberedPeripheralID,
              let peripheral = centralManager.retrievePeripherals(withIdentifiers: [id]).first else {
            managerQueue_startBootstrapPass(reason: "no adopted peripheral")
            return
        }
        managerQueue_adopt(peripheral)
        // Three bursts with a request standing and nothing heard: the identifier is presumed
        // stale (the fork's re-acquire pass, now only ever reached from a wake). A pass that found
        // nothing restarts the count, so a sensor that is simply away is scanned for once per
        // three bursts, not back to back.
        let reference = [lastReadingAt, lastBootstrapAt].compactMap { $0 }.max()
        let missed = G7WatchAcquisition.missedBursts(since: reference)
        if !bootstrapPass, peripheral.state != .connected, missed >= G7WatchAcquisition.missedBurstsBeforeBootstrap {
            if peripheral.state == .connecting { centralManager.cancelPeripheralConnection(peripheral) }
            lodged = false; lodgedAt = nil
            managerQueue_startBootstrapPass(reason: "\(missed) bursts missed on the lodged request")
            return
        }
        let sinceLinkUp = linkUpAt.map { Date().timeIntervalSince($0) } ?? .infinity
        managerQueue_relodge(peripheral, sinceLinkUp: sinceLinkUp, why: "acquisition armed")
    }

    fileprivate func managerQueue_adopt(_ peripheral: CBPeripheral) {
        if let pm = activePeripheralManager { pm.peripheral = peripheral } else {
            activePeripheralManager = G7PeripheralManager(peripheral: peripheral, configuration: .dexcomG7, centralManager: centralManager)
            activePeripheralManager?.delegate = self
        }
        managedPeripherals[peripheral.identifier] = activePeripheralManager
    }

    /// Every close of the adopted sensor, every late connect failure and every wake come through
    /// here: the selected arm decides how the next request reaches the daemon. `sinceLinkUp` is 0
    /// when the clearance must count from now (a failure with no link-up to measure from).
    fileprivate func managerQueue_relodge(_ peripheral: CBPeripheral, sinceLinkUp: TimeInterval, why: String) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard !lodged, !holdPending else { return }
        let arm = G7WatchAcquisition.relodge
        switch G7WatchAcquisition.relodgePlan(arm, sinceLinkUp: sinceLinkUp, anchor: lastReadingAt) {
        case .startDelay(let seconds)?:
            managerQueue_lodge(peripheral, startDelay: seconds, why: "\(why) · \(arm.rawValue): aimed at the next reading")
        case .holdThenConnect(let wait)?:
            holdPending = true
            watchLog(String(format: "%@ · %@: holding the process %.1f s past the sensor's tail, then a plain connect", why, arm.rawValue, wait))
            holdProcess(reason: "G7 re-lodge after the sensor's tail", upTo: wait) { [weak self] systemEnded in
                self?.managerQueue.async {
                    guard let self else { return }
                    self.holdPending = false
                    self.managerQueue_lodge(peripheral, startDelay: nil, why: systemEnded ? "hold ended by the system" : "hold over")
                }
            }
        case nil:
            // A wake past the clearance (holdApp), or peteDelay with no reading on record and the
            // tail long over: nothing to wait for, a plain request now.
            managerQueue_lodge(peripheral, startDelay: nil, why: "\(why) · \(arm.rawValue): nothing to wait for")
        }
    }

    /// ONE request with the daemon. `startDelay` nil = plain connect. Never held, never withdrawn by us.
    fileprivate func managerQueue_lodge(_ peripheral: CBPeripheral, startDelay: Int?, why: String) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard centralManager.state == .poweredOn, !lodged else { return }
        switch peripheral.state {
        case .connected:     return
        case .connecting:
            // NOT trusted. A request this process lodged sets `lodged`, and the guard above
            // returns before reaching here — so a `.connecting` seen with `lodged == false` is
            // a RESTORED snapshot, and on 2026-09-16 23:27 (an install killed the old process
            // mid-hold; the daemon resurrected its zombie session) that snapshot said
            // "connecting" while bluetoothd held NO request: eight hours with no link. Cancel
            // whatever the daemon thinks it holds and lodge our own; the close/fail callback
            // re-lodges through the arm, and the timer covers a cancel that produces no callback.
            watchLog("restored as connecting with no request of ours — cancelling it and lodging a fresh connect")
            centralManager.cancelPeripheralConnection(peripheral)
            let id = peripheral.identifier
            managerQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.lodged,
                      let p = self.centralManager.retrievePeripherals(withIdentifiers: [id]).first, p.state == .disconnected else { return }
                self.managerQueue_lodge(p, startDelay: nil, why: "after cancelling a restored connect the daemon did not hold")
            }
            return
        case .disconnecting: return   // the close callback lodges: a connect issued during a cancel was lost inside CoreBluetooth (2026-09-14 21:12)
        default:             break
        }
        if let delegate, !delegate.bluetoothManagerCanAuthenticate(self) {
            // A link we cannot authenticate is one the sensor closes unencrypted ~10 s later — a
            // tally count every burst for nothing. Stand down; the code's arrival re-arms
            // (G7CGMManager.receivePairingCode → resumeScanning).
            G7WatchDirectRead.needsCodeFor = peripheral.name
            watchLog("no pairing code for \(peripheral.name ?? "sensor") — not lodging")
            return
        }
        G7WatchDirectRead.needsCodeFor = nil
        lodged = true; lodgedAt = Date()
        let options = startDelay.map { [CBConnectPeripheralOptionStartDelayKey: NSNumber(value: $0)] }
        centralManager.connect(peripheral, options: options)
        watchLog("lodged — \(why) · startDelay \(startDelay.map { "\($0) s" } ?? "none") · the app may suspend")
    }

    /// performExpiringActivity, once-only: `onEnd` runs when `wait` elapses, when the system ends the
    /// hold, or when the returned release closure is called — whichever first, exactly once.
    @discardableResult
    fileprivate func holdProcess(reason: String, upTo wait: TimeInterval, onEnd: @escaping (_ systemEnded: Bool) -> Void = { _ in }) -> () -> Void {
        let gate = DispatchSemaphore(value: 0)
        let once = NSLock(); var done = false
        let end: (Bool) -> Void = { s in once.lock(); let first = !done; done = true; once.unlock(); if first { onEnd(s) } }
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
                if expired { end(true); gate.signal(); return }
                _ = gate.wait(timeout: .now() + wait); end(false)
            }
        }
        return { gate.signal() }
    }

    // MARK: bootstrap — the ONE scan pass (fresh install / sensor change / 3 misses / user reconnect)

    fileprivate func managerQueue_startBootstrapPass(reason: String) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard centralManager.state == .poweredOn, !bootstrapPass else { return }
        bootstrapPass = true
        lastBootstrapAt = Date()
        // With no identifier there is nothing else to fall back on, so the scan stays up until the
        // sensor is found. With one, a short pass and then the daemon-held connect is the better bet.
        let untilFound = activePeripheralIdentifier == nil && rememberedPeripheralID == nil
        watchLog(untilFound
                 ? "BOOTSTRAP scan — \(reason) (no identifier yet: scanning until the sensor is found)"
                 : "BOOTSTRAP scan pass — \(reason) (one pass, \(Int(G7WatchAcquisition.bootstrapScanCap)) s cap)")
        let services = [SensorServiceUUID.advertisement.cbUUID, SensorServiceUUID.cgmService.cbUUID]
        for p in centralManager.retrieveConnectedPeripherals(withServices: services) { handleDiscoveredPeripheral(p) }
        centralManager.registerForConnectionEvents(options: [CBConnectionEventMatchingOption.serviceUUIDs: services])
        centralManager.scanForPeripherals(withServices: [SensorServiceUUID.advertisement.cbUUID], options: nil)
        delegate?.bluetoothManagerScanningStatusDidChange(self)
        guard !untilFound else {
            G7WatchDirectRead.setSearching(true)
            return
        }
        let t = DispatchSource.makeTimerSource(queue: managerQueue)
        t.schedule(deadline: .now() + G7WatchAcquisition.bootstrapScanCap)
        t.setEventHandler { [weak self] in self?.managerQueue_endBootstrapPass(reason: "cap reached") }
        t.resume()
        bootstrapTimer = t
    }

    fileprivate func managerQueue_endBootstrapPass(reason: String) {
        guard bootstrapPass else { return }
        bootstrapPass = false
        bootstrapTimer?.cancel(); bootstrapTimer = nil
        managerQueue_stopScanning()
        G7WatchDirectRead.setSearching(false)
        watchLog("bootstrap pass over — \(reason)")
        guard reason != "connected" else { return }
        if let p = activePeripheral, p.state == .connecting { centralManager.cancelPeripheralConnection(p); lodged = false; lodgedAt = nil }
        // Nothing adopted: stand down until the next wake (poweredOn / foreground / the phone's code).
        if activePeripheralIdentifier != nil { managerQueue_watchArm() }
    }

    // MARK: the callbacks

    fileprivate func managerQueue_watchLinkUp(_ peripheral: CBPeripheral) {
        let waited = lodgedAt.map { Date().timeIntervalSince($0) }
        lodged = false; lodgedAt = nil; refusals = 0
        linkUpAt = Date()
        if bootstrapPass { managerQueue_endBootstrapPass(reason: "connected") }
        watchLog(String(format: "link up %@ %@ · pid %d", peripheral.name ?? "unnamed",
                        waited.map { String(format: "%.0f s after the lodge", $0) } ?? "(restored launch)",
                        ProcessInfo.processInfo.processIdentifier))
    }

    /// Returns true when the watch arm owns what happens next (the adopted sensor closed the link).
    fileprivate func managerQueue_watchDidDisconnect(_ peripheral: CBPeripheral, error: Error?) -> Bool {
        guard peripheral.identifier == activePeripheralIdentifier else { return false }
        let sinceLinkUp = linkUpAt.map { Date().timeIntervalSince($0) } ?? 0
        linkUpAt = nil; lodged = false; lodgedAt = nil
        guard !bootstrapPass else { return false }
        let code = (error as NSError?).map { " [\($0.domain)#\($0.code)] \($0.localizedDescription)" } ?? ""
        managerQueue_relodge(peripheral, sinceLinkUp: sinceLinkUp, why: String(format: "sensor closed %.1f s after link-up%@", sinceLinkUp, code))
        return true
    }

    fileprivate func managerQueue_watchDidFailToConnect(_ peripheral: CBPeripheral, error: Error?) -> Bool {
        guard lodged, peripheral.identifier == activePeripheralIdentifier else { return false }
        lodged = false
        let sinceLodge = lodgedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        lodgedAt = nil
        let code = (error as NSError?).map { "\($0.domain)#\($0.code) \($0.localizedDescription)" } ?? "no error"
        let (action, n) = G7WatchAcquisition.onConnectFailure(refusals: refusals, sinceLodge: sinceLodge)
        refusals = n
        switch action {
        case .standDown:
            watchLog("REFUSED twice in a row (\(code)) — standing down until the next wake")
        case .backOff(let s):
            watchLog(String(format: "REFUSED %.2f s after the lodge (%@) — one more lodge in %.0f s", sinceLodge, code, s))
            let id = peripheral.identifier
            managerQueue.asyncAfter(deadline: .now() + s) { [weak self] in
                guard let self, !self.lodged,
                      let p = self.centralManager.retrievePeripherals(withIdentifiers: [id]).first, p.state == .disconnected else { return }
                self.managerQueue_lodge(p, startDelay: nil, why: "after the refusal backoff")
            }
        case .relodge:
            watchLog(String(format: "connect failed %.0f s after the lodge (%@) — re-lodging through the selected arm", sinceLodge, code))
            managerQueue_relodge(peripheral, sinceLinkUp: 0, why: "after a late connect failure")
        }
        return true
    }

}
#endif

/// DIRECT READ on the watch — Loop's own handshake (`G7Authenticator`, session mode `.direct`),
/// so the watch reads glucose with no Dexcom app present. The sensor's pairing code is entered
/// once on the phone and rides to the watch inside the context's cgmManagerState.
public enum G7WatchDirectRead {
    /// Set when a connect reached a sensor we have no code for; cleared as soon as one exists.
    /// Surfaced by the glance and the diagnostics screen — the user's cue to enter it on the phone.
    public static let needsCodeKey = "G7Lab.watchDirectRead.needsCode"
    /// The display slot the watch declares at authentication (`G7DisplayType`): a watch. An
    /// alternating experiment (2026-09-16/17, ~45 bursts as `.medical`, ~30 as `.watch`) found
    /// no difference in burst hit rate or link-up lateness, and the stored key survives either
    /// slot — so the honest declaration it is.
    public static let displayType: G7DisplayType = .watch

    public static var needsCodeFor: String? {
        get { UserDefaults.standard.string(forKey: needsCodeKey) }
        set {
            if let v = newValue { UserDefaults.standard.set(v, forKey: needsCodeKey) }
            else { UserDefaults.standard.removeObject(forKey: needsCodeKey) }
        }
    }

    /// Set while the watch scans for a sensor it has never connected to. Scanning runs at a much
    /// better duty level with the app in front, so the user is asked to keep it open.
    public static let searchingKey = "G7Lab.watchDirectRead.searching"
    public static let searchStateDidChange = Notification.Name("G7WatchDirectReadSearchStateDidChange")

    public static var isSearching: Bool {
        UserDefaults.standard.bool(forKey: searchingKey)
    }

    static func setSearching(_ searching: Bool) {
        guard searching != isSearching else { return }
        UserDefaults.standard.set(searching, forKey: searchingKey)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: searchStateDidChange, object: nil)
        }
    }

    public static var searchingNote: String? {
        isSearching ? "Looking for your sensor — keep Loop open on your watch until it connects." : nil
    }

    /// One-line glance note while a code is missing; nil otherwise.
    public static var needsCodeNote: String? {
        needsCodeFor.map { "Sensor code needed for \($0) — enter it in Loop ▸ Dexcom G7 on the phone (it is shown in the Dexcom app)." }
    }
}

/// The watch's ONE acquisition design (lean-out step 7, 2026-09-16): a single daemon-held request
/// per burst, re-lodged after each close through the arm the Diagnostics page selects. Pure, so
/// WatchAppTests can pin it. The G7BluetoothManager extension above is the stateful half.
public enum G7WatchAcquisition {
    /// How the next request reaches the daemon after each reading (Diagnostics ▸ Sensor ▸ Re-lodge).
    /// `peteDelay`: a start delay aimed at the next reading — Pete's 298 − (now − bg_timestamp);
    /// measured 1 in 4, the daemon serving a delayed connect 0.3–269 s late. `holdApp`: hold the
    /// process 35 s after link-up, then a plain connect; 33 in 33, at 35 s of runtime per cycle.
    public enum Relodge: String, CaseIterable { case peteDelay, holdApp }
    public static let relodgeKey = "G7Lab.relodge"
    public static let relodgeDefault: Relodge = .holdApp
    public static var relodge: Relodge {
        UserDefaults.standard.string(forKey: relodgeKey).flatMap(Relodge.init(rawValue:)) ?? relodgeDefault
    }
    /// Link-up → the ~3.5-s read, the sensor's close, and its 20–24-s advertising tail all sit inside
    /// 35 s. A request that lands after this never reconnects into the tail.
    public static let tailClearanceSeconds: TimeInterval = 35
    /// The sensor's own cadence: reading timestamps sit on an exact 300.000-s grid (crystal drift
    /// ≈ 4 s/day against wall clock).
    public static let period: TimeInterval = 300
    /// The sensor starts advertising +2.0…+3.2 s after its reading's timestamp (61 cycles,
    /// 2026-09-12); grid point n is anchor + n·period + fireOffset.
    public static let fireOffset: TimeInterval = 3
    /// Lead before the burst. Pete (2026-09-15 11:56): "target a couple seconds before the next
    /// expected reading — delay = 298 − (now − bg_timestamp)". period + fireOffset − lead == 298.
    public static let lead: TimeInterval = 5
    public static let missedBurstsBeforeBootstrap = 3
    /// One full window plus jitter: a scan pass that cannot span a burst proves nothing.
    public static let bootstrapScanCap: TimeInterval = 330
    /// Pete's heartbeatFailureBackoffSeconds.
    public static let refusalBackoffSeconds: TimeInterval = 30
    /// A didFailToConnect this soon after the call is the daemon declining the request itself.
    public static let synchronousRefusalWindow: TimeInterval = 2
    // Key STRINGS unchanged from the timed-connect era, so the first build re-adopts without a scan.
    public static let adoptedPeripheralKey = "G7Lab.timedConnect.adoptedPeripheral"
    public static let lastReadingKey = "G7Lab.timedConnect.anchor"

    /// The next grid-aligned fire time strictly after `now + margin`, on the reading's own grid.
    public static func nextFire(anchor: Date, now: Date, margin: TimeInterval = 1) -> Date {
        var n = floor(now.timeIntervalSince(anchor) / period)
        var t = anchor.addingTimeInterval(n * period + fireOffset)
        while t <= now.addingTimeInterval(margin) { n += 1; t = anchor.addingTimeInterval(n * period + fireOffset) }
        return t
    }
    /// Pete's start delay in whole seconds (a fractional or zero NSNumber is refused with CBError 1),
    /// never below 1: with the burst already here a delay would land after it.
    public static func peteDelay(anchor: Date, now: Date) -> Int {
        let seconds = nextFire(anchor: anchor, now: now).timeIntervalSince(now) - lead
        return max(1, Int(seconds.rounded()))
    }
    /// How long the hold arm keeps the process, counted from link-up; never below half a second.
    public static func holdWait(sinceLinkUp: TimeInterval) -> TimeInterval {
        max(0.5, tailClearanceSeconds - sinceLinkUp)
    }
    public enum RelodgePlan: Equatable { case startDelay(seconds: Int), holdThenConnect(wait: TimeInterval) }
    /// nil = nothing to wait for: a plain request now. `anchor` is the last reading's sensor timestamp.
    public static func relodgePlan(_ arm: Relodge = relodge, sinceLinkUp: TimeInterval, anchor: Date?, now: Date = Date()) -> RelodgePlan? {
        if arm == .peteDelay, let anchor = anchor {
            return .startDelay(seconds: peteDelay(anchor: anchor, now: now))
        }
        // holdApp — and peteDelay with no reading on record, which has no grid to aim at: clear the
        // tail the way the hold does rather than lodge a plain connect straight into it.
        return sinceLinkUp < tailClearanceSeconds ? .holdThenConnect(wait: holdWait(sinceLinkUp: sinceLinkUp)) : nil
    }
    public enum FailureAction: Equatable { case backOff(TimeInterval), standDown, relodge }
    /// Pete's shape: a synchronous refusal backs off; two in a row stand down until the next wake.
    /// A late failure (the request went live and could not connect) re-lodges through the arm.
    public static func onConnectFailure(refusals: Int, sinceLodge: TimeInterval) -> (FailureAction, refusals: Int) {
        if sinceLodge < synchronousRefusalWindow {
            let n = refusals + 1
            return n >= 2 ? (.standDown, n) : (.backOff(refusalBackoffSeconds), n)
        }
        return (.relodge, 0)
    }
    /// Whole bursts elapsed since `reference` (the last reading, or the last bootstrap pass).
    public static func missedBursts(since reference: Date?, now: Date = Date()) -> Int {
        reference.map { max(0, Int(now.timeIntervalSince($0) / period)) } ?? 0
    }
}

