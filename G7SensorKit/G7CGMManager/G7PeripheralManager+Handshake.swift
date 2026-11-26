//
//  G7PeripheralManager+Handshake.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation

/// Characteristic-name-addressed I/O, so the pairing handshake can talk in
/// terms of "the authentication characteristic" rather than resolving
/// `CBCharacteristic` objects at every step.
extension G7PeripheralManager {

    /// The largest payload the sensor accepts in one write on the certificate
    /// characteristic. Fixed at the classic ATT default rather than negotiated:
    /// the sensor reassembles by byte count, and a larger MTU buys nothing.
    static let certificateChunkSize = 20

    func characteristic(_ uuid: CGMServiceCharacteristicUUID) throws -> CBCharacteristic {
        guard let service = peripheral.services?.itemWithUUID(SensorServiceUUID.cgmService.cbUUID) else {
            throw PeripheralManagerError.invalidConfiguration
        }
        guard let characteristic = service.characteristics?.itemWithUUID(uuid.cbUUID) else {
            throw PeripheralManagerError.unknownCharacteristic
        }
        return characteristic
    }

    func writeValue(
        _ value: Data,
        for uuid: CGMServiceCharacteristicUUID,
        type: CBCharacteristicWriteType,
        timeout: TimeInterval = 5
    ) throws {
        try writeValue(value, for: characteristic(uuid), type: type, timeout: timeout)
    }

    /// Streams `data` to the certificate characteristic in the chunk size the
    /// sensor expects, one chunk straight after another, as the Dexcom app
    /// sends them (about 1 ms apart). A 40 ms pause after each chunk made a
    /// watch's pairing in the background take about 11 s and spent part of
    /// the system's allowance for a background app's Bluetooth use. Sent back
    /// to back, real sensors accept them on a phone and on a watch.
    func writeCertificateBytes(_ data: Data) throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: G7PeripheralManager.certificateChunkSize, limitedBy: data.endIndex)
                ?? data.endIndex
            try writeValue(data[offset ..< end], for: .certificate, type: .withoutResponse)
            offset = end
        }
    }

    /// A one-line summary of a characteristic's discovered properties, for the
    /// pairing log. Which properties a sensor actually advertises has varied
    /// across firmware, and it is the first thing worth knowing when a
    /// handshake stalls on a real device.
    func describeCharacteristic(_ uuid: CGMServiceCharacteristicUUID) -> String {
        guard let characteristic = try? characteristic(uuid) else {
            return "\(uuid) not discovered"
        }
        var properties = [String]()
        let flags: [(CBCharacteristicProperties, String)] = [
            (.read, "read"),
            (.write, "write"),
            (.writeWithoutResponse, "writeWithoutResponse"),
            (.notify, "notify"),
            (.indicate, "indicate")
        ]
        for (flag, name) in flags where characteristic.properties.contains(flag) {
            properties.append(name)
        }
        return "\(uuid) [\(properties.joined(separator: ","))] notifying=\(characteristic.isNotifying)"
    }
}
