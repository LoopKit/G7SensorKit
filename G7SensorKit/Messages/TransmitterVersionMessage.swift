//
//  TransmitterVersionMessage.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// The reply to a `4A` (transmitter version) request: firmware version,
/// software number, silicon version, and the sensor's serial number.
///
/// 20 bytes, little-endian, no CRC:
///
///     0      opcode echo, 0x4A
///     1      status
///     2-5    firmware version, four bytes (major, minor, revision, build)
///     6-9    software number, u32
///     10-13  silicon version, u32
///     14-19  serial number, u48
///
/// The serial is the number printed on the applicator and encoded in the
/// package barcode, rendered in decimal.
public struct TransmitterVersionMessage: SensorMessage, Equatable {
    public let status: UInt8
    public let firmwareVersion: String
    public let softwareNumber: UInt32
    public let siliconVersion: UInt32
    public let serialNumber: UInt64

    public let data: Data

    /// The serial as printed on the sensor's packaging.
    public var serialNumberString: String {
        String(serialNumber)
    }

    init?(data: Data) {
        self.data = data

        guard data.starts(with: .transmitterVersion), data.count >= 20 else {
            return nil
        }

        let base = data.startIndex
        status = data[base + 1]
        firmwareVersion = (2 ... 5).map { String(data[base + $0]) }.joined(separator: ".")
        softwareNumber = data[base + 6 ..< base + 10].to(UInt32.self)
        siliconVersion = data[base + 10 ..< base + 14].to(UInt32.self)

        var serial: UInt64 = 0
        for byte in data[base + 14 ..< base + 20].reversed() {
            serial = serial << 8 | UInt64(byte)
        }
        serialNumber = serial
    }
}

extension TransmitterVersionMessage: CustomDebugStringConvertible {
    public var debugDescription: String {
        "TransmitterVersionMessage(firmware:\(firmwareVersion) softwareNumber:\(softwareNumber) siliconVersion:\(siliconVersion) serial:\(serialNumberString))"
    }
}
