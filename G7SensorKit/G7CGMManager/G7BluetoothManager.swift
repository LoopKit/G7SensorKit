//
//  G7BluetoothManager.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 11/11/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import os.log


protocol G7BluetoothManagerDelegate: AnyObject {

    /**
     Tells the delegate that the bluetooth manager has finished connecting to and discovering all required services of its peripheral, or that it failed to do so

     - parameter manager: The bluetooth manager
     - parameter peripheralManager: The peripheral manager
     - parameter error:   An error describing why bluetooth setup failed
     */
    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, isReadyWithError error: Error?)

    /**
     Asks the delegate whether the discovered or restored peripheral should be connected

     - parameter manager:    The bluetooth manager
     - parameter peripheral: The found peripheral

     - returns: True if the peripheral should connect
     */
    func bluetoothManager(_ manager: G7BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral) -> Bool

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
}


class G7BluetoothManager: NSObject {

    var stayConnected: Bool {
        get {
            return lockedStayConnected.value
        }
        set {
            lockedStayConnected.value = newValue
        }
    }
    private let lockedStayConnected: Locked<Bool> = Locked(true)

    var scanWhileConnecting: Bool {
        get {
            return lockedScanWhileConnecting.value
        }
        set {
            lockedScanWhileConnecting.value = newValue
        }
    }
    private let lockedScanWhileConnecting: Locked<Bool> = Locked(false)


    weak var delegate: G7BluetoothManagerDelegate?

    private let log = OSLog(category: "G7BluetoothManager")

    /// Isolated to `managerQueue`
    private var centralManager: CBCentralManager! = nil

    /// Isolated to `managerQueue`
    private var peripheral: CBPeripheral? {
        get {
            return peripheralManager?.peripheral
        }
        set {
            guard let peripheral = newValue else {
                peripheralManager = nil
                return
            }

            if let peripheralManager = peripheralManager {
                peripheralManager.peripheral = peripheral
            } else {
                peripheralManager = G7PeripheralManager(
                    peripheral: peripheral,
                    configuration: .dexcomG7,
                    centralManager: centralManager
                )
            }
        }
    }

    var peripheralIdentifier: UUID? {
        get {
            return lockedPeripheralIdentifier.value
        }
        set {
            lockedPeripheralIdentifier.value = newValue
        }
    }
    private let lockedPeripheralIdentifier: Locked<UUID?> = Locked(nil)

    /// Isolated to `managerQueue`
    private var peripheralManager: G7PeripheralManager? {
        didSet {
            oldValue?.delegate = nil
            peripheralManager?.delegate = self

            peripheralIdentifier = peripheralManager?.peripheral.identifier
        }
    }

    // MARK: - Synchronization

    private let managerQueue = DispatchQueue(label: "com.loudnate.CGMBLEKit.bluetoothManagerQueue", qos: .unspecified)

    override init() {
        super.init()

        managerQueue.sync {
            self.centralManager = CBCentralManager(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.loudnate.CGMBLEKit"])
        }
    }

    // MARK: - Actions

    func scanForPeripheral() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            self.managerQueue_scanForPeripheral()
        }
    }

    func forgetPeripheral() {
        managerQueue.sync {
            self.peripheralManager = nil
        }
    }

    func stopScanning() {
        managerQueue.sync {
            if centralManager.isScanning {
                log.debug("Stopping scan")
                centralManager.stopScan()
                delegate?.bluetoothManagerScanningStatusDidChange(self)
            }
        }
    }

    func disconnect() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            if centralManager.isScanning {
                log.debug("Stopping scan on disconnect")
                centralManager.stopScan()
                delegate?.bluetoothManagerScanningStatusDidChange(self)
            }

            if let peripheral = peripheral {
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }
    }

    private func managerQueue_scanForPeripheral() {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        guard centralManager.state == .poweredOn else {
            return
        }

        let currentState = peripheral?.state ?? .disconnected
        guard currentState != .connected else {
            return
        }

        if let peripheralID = peripheralIdentifier, let peripheral = centralManager.retrievePeripherals(withIdentifiers: [peripheralID]).first {
            log.debug("Re-connecting to known peripheral %{public}@", peripheral.identifier.uuidString)
            self.peripheral = peripheral
            self.centralManager.connect(peripheral)
        } else {
            for peripheral in centralManager.retrieveConnectedPeripherals(withServices: [
                SensorServiceUUID.advertisement.cbUUID,
                SensorServiceUUID.cgmService.cbUUID
            ]) {
                if delegate == nil || delegate!.bluetoothManager(self, shouldConnectPeripheral: peripheral) {
                    log.debug("Found system-connected peripheral: %{public}@", peripheral.identifier.uuidString)
                    self.peripheral = peripheral
                    self.centralManager.connect(peripheral)
                    break
                }
            }
        }

        if peripheral == nil || scanWhileConnecting {
            log.debug("Scanning for peripherals")
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
            isConnected = peripheral?.state == .connected
        }
        return isConnected
    }

    override var debugDescription: String {
        return [
            "## BluetoothManager",
            peripheralManager.map(String.init(reflecting:)) ?? "No peripheral",
        ].joined(separator: "\n")
    }
}


extension G7BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        peripheralManager?.centralManagerDidUpdateState(central)
        log.default("%{public}@: %{public}@", #function, String(describing: central.state.rawValue))

        switch central.state {
        case .poweredOn:
            managerQueue_scanForPeripheral()
        case .resetting, .poweredOff, .unauthorized, .unknown, .unsupported:
            fallthrough
        @unknown default:
            if central.isScanning {
                log.debug("Stopping scan on central not powered on")
                central.stopScan()
                delegate?.bluetoothManagerScanningStatusDidChange(self)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                if delegate == nil || delegate!.bluetoothManager(self, shouldConnectPeripheral: peripheral) {
                    log.default("Restoring peripheral from state: %{public}@", peripheral.identifier.uuidString)
                    self.peripheral = peripheral
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.info("%{public}@: %{public}@, data = %{public}@", #function, peripheral, String(describing: advertisementData))
        if delegate == nil || delegate!.bluetoothManager(self, shouldConnectPeripheral: peripheral) {
            self.peripheral = peripheral

            central.connect(peripheral, options: nil)

            if central.isScanning && !scanWhileConnecting {
                log.debug("Stopping scan")
                central.stopScan()
                delegate?.bluetoothManagerScanningStatusDidChange(self)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("%{public}@: %{public}@", #function, peripheral)
        if central.isScanning && !scanWhileConnecting {
            log.debug("Stopping scan")
            central.stopScan()
            delegate?.bluetoothManagerScanningStatusDidChange(self)
        }

        peripheralManager?.centralManager(central, didConnect: peripheral)

        if case .poweredOn = centralManager.state, case .connected = peripheral.state, let peripheralManager = peripheralManager {
            self.delegate?.bluetoothManager(self, peripheralManager: peripheralManager, isReadyWithError: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        log.default("%{public}@: %{public}@", #function, peripheral)
        // Ignore errors indicating the peripheral disconnected remotely, as that's expected behavior
        if let error = error as NSError?, CBError(_nsError: error).code != .peripheralDisconnected {
            log.error("%{public}@: %{public}@", #function, error)
            if let peripheralManager = peripheralManager {
                self.delegate?.bluetoothManager(self, peripheralManager: peripheralManager, isReadyWithError: error)
            }
        }

        if stayConnected {
            scanAfterDelay()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.error("%{public}@: %{public}@", #function, String(describing: error))
        if let error = error, let peripheralManager = peripheralManager {
            self.delegate?.bluetoothManager(self, peripheralManager: peripheralManager, isReadyWithError: error)
        }

        if stayConnected {
            scanAfterDelay()
        }
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
        case .none, .communication?:
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
