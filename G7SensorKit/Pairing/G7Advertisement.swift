//
//  G7Advertisement.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  Derived from DexKit by Erik Tolboom (https://github.com/nightscout/DexKit).
//

import CoreBluetooth
import Foundation

/// What a G7-family sensor says about itself before anyone connects.
///
/// The manufacturer-data field of its advertisement is
/// `d0 00 | CRC16-XMODEM(serial) LE | types-in-use | 04`, where the CRC is
/// over the ASCII digits of the serial printed on the package, and
/// types-in-use records which kinds of display currently hold a slot.
///
/// Two things fall out of that without a connection:
///
/// - Whether this sensor can be the one whose package was scanned, so pairing
///   need not try every sensor in range.
/// - Whether some display has connected in the last ~15 minutes. A sensor
///   admits one display, and it keeps advertising the slot as held for that
///   long after the display goes quiet. While held it refuses other displays,
///   and refusing four times in a row makes it stop accepting connections
///   for a while, so a held slot is a reason to try other sensors first.
struct G7Advertisement: Equatable {

    /// The name the sensor advertises before it is paired: "DXCMxx" (G7),
    /// "DX02xx" (ONE+) or "DX01xx" (Stelo). The full "Dexcomxx" name only
    /// appears once connected.
    let name: String

    /// CRC16-XMODEM of the serial's ASCII digits, when the manufacturer data
    /// was present and well formed.
    let serialChecksum: UInt16?

    /// The types-in-use byte: which display types currently hold a slot.
    /// Nil when the advertisement did not say.
    let typesInUse: UInt8?

    /// Whether a display of this type currently holds its slot on the sensor.
    func isSlotHeld(for displayType: G7DisplayType) -> Bool? {
        typesInUse.map { $0 & displayType.typesInUseMask != 0 }
    }

    var isPhoneSlotHeld: Bool? {
        isSlotHeld(for: .phone)
    }

    init?(peripheral: CBPeripheral, advertisementData: [String: Any]) {
        guard let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name else {
            return nil
        }
        self.init(name: name, manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)
    }

    init(name: String, manufacturerData: Data?) {
        self.name = name

        guard let data = manufacturerData.map({ Data($0) }),
              data.count >= 5,
              data[0] == 0xD0, data[1] == 0x00
        else {
            serialChecksum = nil
            typesInUse = nil
            return
        }

        serialChecksum = UInt16(data[2]) | UInt16(data[3]) << 8
        typesInUse = data[4]
    }

    /// Whether this looks like a sensor family we know how to pair with.
    var isSupportedSensor: Bool {
        G7SensorModel(advertisedName: name) != nil
    }

    var model: G7SensorModel? {
        G7SensorModel(advertisedName: name)
    }

    /// Whether this sensor could be the one with `serial` on its package.
    ///
    /// Unknown is treated as possible: an advertisement without the checksum
    /// costs a wasted handshake at worst, while wrongly excluding the user's
    /// own sensor would make pairing impossible.
    func couldHaveSerial(_ serial: String) -> Bool {
        guard let serialChecksum = serialChecksum,
              let expected = G7Advertisement.serialChecksum(for: serial)
        else {
            return true
        }
        return serialChecksum == expected
    }

    /// The checksum a sensor with `serial` advertises, or nil when `serial`
    /// is not plain ASCII digits.
    static func serialChecksum(for serial: String) -> UInt16? {
        let digits = Array(serial.utf8)
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            return nil
        }
        return CRC16.xmodem(digits)
    }
}

enum CRC16 {
    /// CRC-16/XMODEM: polynomial 0x1021, zero initial value, no reflection.
    static func xmodem<Bytes: Sequence>(_ bytes: Bytes) -> UInt16 where Bytes.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0 ..< 8 {
                crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}
