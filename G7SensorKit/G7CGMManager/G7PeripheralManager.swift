//
//  G7PeripheralManager.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 11/11/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import os.log


enum PeripheralManagerError: Error {
    case cbPeripheralError(Error)
    case notReady
    case invalidConfiguration
    case timeout
    case unknownCharacteristic
}

class G7PeripheralManager: NSObject {

    private let log = OSLog(category: "G7PeripheralManager")

    ///
    /// This is mutable, because CBPeripheral instances can seemingly become invalid, and need to be periodically re-fetched from CBCentralManager
    var peripheral: CBPeripheral {
        didSet {
            guard oldValue !== peripheral else {
                return
            }

            log.error("Replacing peripheral reference %{public}@ -> %{public}@", oldValue, peripheral)

            oldValue.delegate = nil
            peripheral.delegate = self

            queue.sync {
                self.needsConfiguration = true
            }
        }
    }

    /// Makes this manager the peripheral's delegate again, in case another
    /// manager for the same peripheral took the role in the meantime.
    func reclaimPeripheral() {
        if peripheral.delegate !== self {
            log.error("Reclaiming peripheral %{public}@ from %{public}@", peripheral, String(describing: peripheral.delegate))
            peripheral.delegate = self
        }
    }

    /// The dispatch queue used to serialize operations on the peripheral
    let queue = DispatchQueue(label: "com.loopkit.PeripheralManager.queue", qos: .unspecified)

    /// The condition used to signal command completion
    private let commandLock = NSCondition()

    /// The required conditions for the operation to complete
    private var commandConditions = [CommandCondition]()

    /// Any error surfaced during the active operation
    private var commandError: Error?

    /// Persistent per-characteristic update handlers. The pairing handshake
    /// installs these to collect streamed chunks, which the one-shot command
    /// conditions cannot do: the sensor starts streaming on the certificate
    /// characteristic before its acknowledgement lands on the authentication
    /// characteristic, and acknowledgements themselves can arrive while our
    /// own write is still pending. Guarded by `commandLock`.
    private var valueUpdateHandlers: [CBUUID: (Data) -> Void] = [:]

    /// Setup requests whose replies haven't arrived. A command for one of these waits for that
    /// reply instead of sending its own. Guarded by `commandLock`.
    private var earlyInFlight: Set<String> = []

    /// Discovery requests sent on this link, so a reply missing what we asked for ends discovery
    /// instead of repeating it. Guarded by `commandLock`.
    private var discoveryRequested: Set<String> = []

    /// Characteristics to subscribe to once discovery finishes. Guarded by `commandLock`.
    private var earlySubscriptions: [CBUUID]?

    private(set) weak var central: CBCentralManager?

    let configuration: Configuration

    // Confined to `queue`
    private var needsConfiguration = true

    weak var delegate: G7PeripheralManagerDelegate? {
        didSet {
            queue.sync {
                needsConfiguration = true
            }
        }
    }

    init(peripheral: CBPeripheral, configuration: Configuration, centralManager: CBCentralManager) {
        self.peripheral = peripheral
        self.central = centralManager
        self.configuration = configuration

        super.init()

        peripheral.delegate = self

        assertConfiguration()
    }

    /// Installs (or with a nil handler, removes) a persistent handler that
    /// receives every value update for `characteristic`, ahead of the
    /// unsolicited-notification path to the delegate.
    func setValueUpdateHandler(for characteristic: CGMServiceCharacteristicUUID, handler: ((Data) -> Void)?) {
        commandLock.lock()
        valueUpdateHandlers[characteristic.cbUUID] = handler
        commandLock.unlock()
    }

    func requestExtendedVersion() throws {
        self.log.default("Requesting sensor extended version");
        guard let service = peripheral.services?.itemWithUUID(SensorServiceUUID.cgmService.cbUUID) else {
            self.log.error("Peripheral missing cgm service. Services = %{public}@", String(describing: peripheral.services));
            throw PeripheralManagerError.invalidConfiguration
        }

        guard let characteristic = service.characteristics?.itemWithUUID(CGMServiceCharacteristicUUID.control.cbUUID) else {
            throw PeripheralManagerError.unknownCharacteristic
        }

        try writeValue(Data([G7Opcode.extendedVersionTx.rawValue]), for: characteristic, type: .withResponse, timeout: 1)
    }
}


// MARK: - Nested types
extension G7PeripheralManager {
    struct Configuration {
        var serviceCharacteristics: [CBUUID: [CBUUID]] = [:]
        var notifyingCharacteristics: [CBUUID: [CBUUID]] = [:]
        var valueUpdateMacros: [CBUUID: (_ manager: G7PeripheralManager) -> Void] = [:]
    }

    enum CommandCondition {
        case notificationStateUpdate(characteristicUUID: CBUUID, enabled: Bool)
        case valueUpdate(characteristic: CBCharacteristic, matching: ((Data?) -> Bool)?)
        case write(characteristic: CBCharacteristic)
        case discovery
    }
}

protocol G7PeripheralManagerDelegate: AnyObject {
    func peripheralManager(_ manager: G7PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic)

    func peripheralManager(_ manager: G7PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?)

    func peripheralManagerDidUpdateName(_ manager: G7PeripheralManager)

    func completeConfiguration(for manager: G7PeripheralManager) throws
}


// MARK: - Operation sequence management
extension G7PeripheralManager {
    func configureAndRun(_ block: @escaping (_ manager: G7PeripheralManager) -> Void) -> (() -> Void) {
        return {
            let undiscovered = self.hasUndiscoveredCharacteristics
            if !self.needsConfiguration && undiscovered {
                self.log.error("Configured peripheral has undiscovered characteristics. Reconfiguring…")
            }

            if self.needsConfiguration || undiscovered {
                do {
                    try self.applyConfiguration()
                    self.log.default("Peripheral configuration completed")
                    if let delegate = self.delegate {
                        try delegate.completeConfiguration(for: self)
                        self.log.default("Delegate configuration completed")
                        self.needsConfiguration = false
                    } else {
                        self.log.error("No delegate set configured")
                    }
                } catch let error {
                    self.log.error("Error applying peripheral configuration: %{public}@", String(describing: error))
                    // Will retry
                }

            }

            block(self)
        }
    }

    /// The early setup can leave a link with its services discovered and its characteristics not yet.
    private var hasUndiscoveredCharacteristics: Bool {
        guard let services = peripheral.services else { return true }
        return configuration.serviceCharacteristics.contains { serviceUUID, characteristicUUIDs in
            guard let service = services.itemWithUUID(serviceUUID) else { return true }
            return !peripheral.characteristicsToDiscover(from: characteristicUUIDs, for: service).isEmpty
        }
    }

    /// Sends discovery and the given subscriptions straight from the connect callback, each
    /// as soon as the previous reply arrives, without waiting for the peripheral queue.
    func startEarlySetup(subscribing characteristics: [CGMServiceCharacteristicUUID]) {
        commandLock.lock()
        defer { commandLock.unlock() }
        earlyInFlight.removeAll()
        discoveryRequested.removeAll()
        earlySubscriptions = characteristics.map(\.cbUUID)
        continueSetupLocked()
    }

    /// Replies to a closed link never arrive, so their requests mustn't stay marked in flight.
    func endEarlySetup() {
        commandLock.lock()
        earlySubscriptions = nil
        earlyInFlight.removeAll()
        discoveryRequested.removeAll()
        finishDiscoveryLocked(error: PeripheralManagerError.notReady)
        commandLock.unlock()
    }

    /// The only place discovery is requested. Each reply calls back in here, so the steps run as
    /// fast as the sensor answers whether the peripheral queue is running or not.
    private func continueSetupLocked() {
        guard peripheral.state == .connected else { return }
        let services = peripheral.services ?? []
        let configured = configuration.serviceCharacteristics

        if configured.keys.contains(where: { services.itemWithUUID($0) == nil }) {
            requestDiscovery("services") {
                peripheral.discoverServices(Array(configured.keys))
            }
            return
        }

        var pending = false
        for (serviceUUID, characteristicUUIDs) in configured {
            guard let service = services.itemWithUUID(serviceUUID) else { continue }
            let missing = peripheral.characteristicsToDiscover(from: characteristicUUIDs, for: service)
            if !missing.isEmpty {
                pending = true
                requestDiscovery("characteristics \(serviceUUID.uuidString)") {
                    peripheral.discoverCharacteristics(missing, for: service)
                }
            }
        }
        guard !pending else { return }

        if let subscriptions = earlySubscriptions, let service = services.itemWithUUID(SensorServiceUUID.cgmService.cbUUID) {
            earlySubscriptions = nil
            for uuid in subscriptions {
                if let characteristic = service.characteristics?.itemWithUUID(uuid), !characteristic.isNotifying {
                    earlyInFlight.insert("notify \(uuid.uuidString)")
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
        finishDiscoveryLocked(error: nil)
    }

    /// Sends a discovery request unless it is in flight, or was answered without what we asked for.
    private func requestDiscovery(_ key: String, send: () -> Void) {
        guard !earlyInFlight.contains(key) else { return }
        guard !discoveryRequested.contains(key) else {
            finishDiscoveryLocked(error: PeripheralManagerError.unknownCharacteristic)
            return
        }
        earlyInFlight.insert(key)
        discoveryRequested.insert(key)
        send()
    }

    /// Releases a queued step waiting on discovery. Requires `commandLock`.
    private func finishDiscoveryLocked(error: Error?) {
        guard let index = commandConditions.firstIndex(where: { if case .discovery = $0 { return true } else { return false } }) else {
            return
        }
        commandConditions.remove(at: index)
        commandError = error
        if commandConditions.isEmpty {
            commandLock.broadcast()
        }
    }

    /// Waits for the callback-driven setup to finish discovery, starting it if nothing has.
    private func awaitDiscovery(timeout: TimeInterval) throws {
        try runCommand(timeout: timeout) {
            guard hasUndiscoveredCharacteristics else { return }
            addCondition(.discovery)
            continueSetupLocked()
            if commandConditions.isEmpty {
                // Finished without waiting; the check below reports a failure.
                commandError = nil
            }
        }
        if hasUndiscoveredCharacteristics {
            log.error("Discovery incomplete on %{public}@ — discovered: %{public}@", peripheral.name ?? "unnamed", Self.gattInventory(peripheral))
            throw PeripheralManagerError.unknownCharacteristic
        }
    }

    func perform(_ block: @escaping (_ manager: G7PeripheralManager) -> Void) {
        queue.async(execute: configureAndRun(block))
    }

    private func assertConfiguration() {
        log.debug("assertConfiguration")
        perform { (_) in
            // Intentionally empty to trigger configuration if necessary
        }
    }

    private func applyConfiguration(discoveryTimeout: TimeInterval = 2) throws {
        try awaitDiscovery(timeout: discoveryTimeout)

        for (serviceUUID, characteristicUUIDs) in configuration.notifyingCharacteristics {
            guard let service = peripheral.services?.itemWithUUID(serviceUUID) else {
                // Log what discovery returned: an empty or partial inventory means the link dropped
                // mid-discovery, a full but different one means unexpected GATT.
                log.error("unknownCharacteristic: service %{public}@ MISSING on %{public}@ — discovered: %{public}@", String(serviceUUID.uuidString.prefix(8)), peripheral.name ?? "unnamed", Self.gattInventory(peripheral))
                throw PeripheralManagerError.unknownCharacteristic
            }

            for characteristicUUID in characteristicUUIDs {
                guard let characteristic = service.characteristics?.itemWithUUID(characteristicUUID) else {
                    log.error("unknownCharacteristic: char %{public}@ MISSING in service %{public}@ on %{public}@ — discovered: %{public}@", String(characteristicUUID.uuidString.prefix(8)), String(serviceUUID.uuidString.prefix(8)), peripheral.name ?? "unnamed", Self.gattInventory(peripheral))
                    throw PeripheralManagerError.unknownCharacteristic
                }

                guard !characteristic.isNotifying else {
                    continue
                }

                try setNotifyValue(true, for: characteristic, timeout: discoveryTimeout)
            }
        }
    }

    /// One-line GATT inventory — "svc(8chars):[char8,char8] | svc:[...]".
    /// nil services = discovery never completed at all.
    static func gattInventory(_ peripheral: CBPeripheral) -> String {
        guard let services = peripheral.services else { return "NO SERVICES (discovery incomplete)" }
        if services.isEmpty { return "0 services" }
        return services.map { svc in
            let chars = svc.characteristics?.map { String($0.uuid.uuidString.prefix(8)) }.joined(separator: ",") ?? "none-discovered"
            return "\(svc.uuid.uuidString.prefix(8)):[\(chars)]"
        }.joined(separator: " | ")
    }
}

extension CBManagerState {
    var description: String {
        switch self {
        case .poweredOff:
            return "poweredOff"
        case .poweredOn:
            return "poweredOn"
        case .resetting:
            return "resetting"
        case .unauthorized:
            return "unauthorized"
        case .unknown:
            return "unknown"
        case .unsupported:
            return "unsupported"
        @unknown default:
            return "unknown(\(rawValue))"
        }
    }
}

extension CBPeripheralState {
    var description: String {
        switch self {
        case .connected:
            return "connected"
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .disconnecting:
            return "disconnecting"
        @unknown default:
            return "unknown(\(rawValue))"
        }
    }
}


// MARK: - Synchronous Commands
extension G7PeripheralManager {
    /// - Throws: PeripheralManagerError
    func runCommand(timeout: TimeInterval, command: () -> Void) throws {
        // Prelude
        dispatchPrecondition(condition: .onQueue(queue))
        guard central?.state == .poweredOn && peripheral.state == .connected else {
            log.debug("Unable to run command: central state = %{public}@, peripheral state = %{public}@", String(describing: central?.state.description), String(describing: peripheral.state))
            throw PeripheralManagerError.notReady
        }

        commandLock.lock()

        defer {
            commandLock.unlock()
        }

        guard commandConditions.isEmpty else {
            throw PeripheralManagerError.invalidConfiguration
        }

        // Run
        command()

        guard !commandConditions.isEmpty else {
            // If the command didn't add any conditions, then finish immediately
            return
        }

        // Postlude
        let signaled = commandLock.wait(until: Date(timeIntervalSinceNow: timeout))

        defer {
            commandError = nil
            commandConditions = []
        }

        guard signaled else {
            throw PeripheralManagerError.timeout
        }

        if let error = commandError {
            throw PeripheralManagerError.cbPeripheralError(error)
        }
    }

    /// It's illegal to call this without first acquiring the commandLock
    ///
    /// - Parameter condition: The condition to add
    func addCondition(_ condition: CommandCondition) {
        dispatchPrecondition(condition: .onQueue(queue))
        commandConditions.append(condition)
    }

    /// - Throws: PeripheralManagerError
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic, timeout: TimeInterval) throws {
        try runCommand(timeout: timeout) {
            let early = enabled && earlyInFlight.contains("notify \(characteristic.uuid.uuidString)")
            guard early || characteristic.isNotifying != enabled else { return }
            addCondition(.notificationStateUpdate(characteristicUUID: characteristic.uuid, enabled: enabled))
            log.debug("Set notify %@ for %@", String(describing: enabled), String(describing: peripheral))
            if !early {
                peripheral.setNotifyValue(enabled, for: characteristic)
            }
        }
    }

    /// - Throws: PeripheralManagerError
    func readValue(for characteristic: CBCharacteristic, timeout: TimeInterval) throws -> Data? {
        try runCommand(timeout: timeout) {
            addCondition(.valueUpdate(characteristic: characteristic, matching: nil))

            peripheral.readValue(for: characteristic)
        }

        return characteristic.value
    }

    /// - Throws: PeripheralManagerError
    func wait(for characteristic: CBCharacteristic, timeout: TimeInterval) throws -> Data {
        try runCommand(timeout: timeout) {
            addCondition(.valueUpdate(characteristic: characteristic, matching: nil))
        }

        guard let value = characteristic.value else {
            throw PeripheralManagerError.timeout
        }

        return value
    }

    /// - Throws: PeripheralManagerError
    func writeValue(_ value: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType, timeout: TimeInterval) throws {
        try runCommand(timeout: timeout) {
            if case .withResponse = type {
                addCondition(.write(characteristic: characteristic))
            }

            peripheral.writeValue(value, for: characteristic, type: type)
        }
    }
}


// MARK: - Delegate methods executed on the central's queue
extension G7PeripheralManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        discoveryReplied("services", error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        discoveryReplied("characteristics \(service.uuid.uuidString)", error: error)
    }

    private func discoveryReplied(_ key: String, error: Error?) {
        commandLock.lock()
        defer { commandLock.unlock() }
        earlyInFlight.remove(key)
        if let error = error {
            finishDiscoveryLocked(error: error)
        } else {
            continueSetupLocked()
        }
    }

    /// Logs an update's error, which the command machinery otherwise drops. watchOS reports its
    /// background-runtime budget here (WWDC22 10135): CBError 18 = near the limit, 17 = exceeded.
    private func reportGattError(_ error: Error?, during what: String, on characteristic: CBCharacteristic) {
        guard let error = error else { return }
        let ns = error as NSError
        var tag = ""
        if ns.domain == CBErrorDomain {
            switch ns.code {
            case 18: tag = " — NEAR the watchOS background-notification limit (CBError 18); the next background wake may be the last before the reset"
            case 17: tag = " — EXCEEDED the watchOS background-notification limit (CBError 17); no background BLE runtime until the user interacts with the app or 24 h pass"
            default: break
            }
        }
        log.error("[gatt] %{public}@ error on %{public}@ — %{public}@ (%{public}@)", what, characteristic.uuid.uuidString, error.localizedDescription, "\(ns.domain)#\(ns.code)\(tag)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        reportGattError(error, during: "notification-state update", on: characteristic)
        commandLock.lock()
        earlyInFlight.remove("notify \(characteristic.uuid.uuidString)")

        // On an error the state does not change, so match the characteristic
        // alone; otherwise the error is lost and the command only times out.
        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .notificationStateUpdate(characteristicUUID: characteristic.uuid, enabled: let enabled) = condition {
                return error != nil || enabled == characteristic.isNotifying
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .write(characteristic: characteristic) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        reportGattError(error, during: "value update", on: characteristic)
        commandLock.lock()

        var notifyDelegate = false
        var streamedValue: (handler: (Data) -> Void, value: Data)?

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .valueUpdate(characteristic: characteristic, matching: let matching) = condition {
                return matching?(characteristic.value) ?? true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        } else if let handler = valueUpdateHandlers[characteristic.uuid], let value = characteristic.value {
            // Deliberately ahead of the `commandConditions.isEmpty` gate below:
            // handshake traffic arrives while our own writes are still pending,
            // and dropping it there is what an installed handler exists to avoid.
            streamedValue = (handler, value) // execute after the unlock
        } else if let macro = configuration.valueUpdateMacros[characteristic.uuid] {
            macro(self)
        } else {
            // Unconditionally, pending command or not. The sensor answers a
            // control write with a notification a moment after the write
            // response, and if the next write (a backfill request) is already
            // in flight by then, gating on "no command pending" threw the
            // glucose reply away. Seen in the field as signal loss while the
            // sensor connected on schedule every five minutes.
            notifyDelegate = true // execute after the unlock
        }

        commandLock.unlock()

        if let streamedValue = streamedValue {
            streamedValue.handler(streamedValue.value)
        }

        if notifyDelegate {
            // If we weren't expecting this notification, pass it along to the delegate
            delegate?.peripheralManager(self, didUpdateValueFor: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        delegate?.peripheralManager(self, didReadRSSI: RSSI, error: error)
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        delegate?.peripheralManagerDidUpdateName(self)
    }
}


extension G7PeripheralManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log.debug("centralManagerDidUpdateState to poweredOn")
            assertConfiguration()
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.debug("didConnect to %{public}@", peripheral.identifier.uuidString)
        switch peripheral.state {
        case .connected:
            assertConfiguration()
        default:
            break
        }
    }
}


extension G7PeripheralManager {
    public override var debugDescription: String {
        var items = [
            "## G7PeripheralManager",
            "peripheral: \(peripheral)",
        ]
        queue.sync {
            items.append("needsConfiguration: \(needsConfiguration)")
        }
        return items.joined(separator: "\n")
    }
}

extension G7PeripheralManager {
    private func getCharacteristicWithUUID(_ uuid: CGMServiceCharacteristicUUID) -> CBCharacteristic? {
        return peripheral.getCharacteristicWithUUID(uuid)
    }

    func setNotifyValue(_ enabled: Bool,
        for characteristicUUID: CGMServiceCharacteristicUUID,
        timeout: TimeInterval = 2) throws
    {
        guard let characteristic = getCharacteristicWithUUID(characteristicUUID) else {
            throw PeripheralManagerError.unknownCharacteristic
        }

        try setNotifyValue(enabled, for: characteristic, timeout: timeout)
    }

    func isNotifying(_ characteristicUUID: CGMServiceCharacteristicUUID) -> Bool {
        return getCharacteristicWithUUID(characteristicUUID)?.isNotifying ?? false
    }

}


fileprivate extension CBPeripheral {
    func getServiceWithUUID(_ uuid: SensorServiceUUID) -> CBService? {
        return services?.itemWithUUIDString(uuid.rawValue)
    }

    func getCharacteristicForServiceUUID(_ serviceUUID: SensorServiceUUID, withUUIDString UUIDString: String) -> CBCharacteristic? {
        guard let characteristics = getServiceWithUUID(serviceUUID)?.characteristics else {
            return nil
        }

        return characteristics.itemWithUUIDString(UUIDString)
    }

    func getCharacteristicWithUUID(_ uuid: CGMServiceCharacteristicUUID) -> CBCharacteristic? {
        return getCharacteristicForServiceUUID(.cgmService, withUUIDString: uuid.rawValue)
    }
}
