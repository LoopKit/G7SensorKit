//
//  G7AdvertisementTests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import G7SensorKit

class G7AdvertisementTests: XCTestCase {

    /// The standard CRC-16/XMODEM check value.
    func testCRC16Xmodem() {
        XCTAssertEqual(CRC16.xmodem(Array("123456789".utf8)), 0x31C3)
        XCTAssertEqual(CRC16.xmodem([]), 0)
    }

    private func manufacturerData(serial: String, typesInUse: UInt8) -> Data {
        let crc = CRC16.xmodem(Array(serial.utf8))
        return Data([0xD0, 0x00, UInt8(crc & 0xFF), UInt8(crc >> 8), typesInUse, 0x04])
    }

    func testParsesSerialChecksumAndSlot() {
        let advertisement = G7Advertisement(name: "DXCM12", manufacturerData: manufacturerData(serial: "123456789012", typesInUse: 0x02))
        XCTAssertEqual(advertisement.serialChecksum, CRC16.xmodem(Array("123456789012".utf8)))
        XCTAssertEqual(advertisement.isPhoneSlotHeld, true)
        XCTAssertTrue(advertisement.isSupportedSensor)
    }

    func testFreeSlot() {
        let advertisement = G7Advertisement(name: "DX0212", manufacturerData: manufacturerData(serial: "1", typesInUse: 0x00))
        XCTAssertEqual(advertisement.isPhoneSlotHeld, false)
        XCTAssertTrue(advertisement.isSupportedSensor)
    }

    func testSerialMatching() {
        let advertisement = G7Advertisement(name: "DXCM12", manufacturerData: manufacturerData(serial: "123456789012", typesInUse: 0))
        XCTAssertTrue(advertisement.couldHaveSerial("123456789012"))
        XCTAssertFalse(advertisement.couldHaveSerial("123456789013"))
    }

    /// Missing or malformed data must never exclude a sensor: the cost of a
    /// wasted handshake is small, the cost of ignoring the user's own sensor
    /// is a pairing that can never succeed.
    func testUnknownAdvertisementIsNotExcluded() {
        for data in [nil, Data(), Data([0xD0, 0x00, 0x01]), Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])] {
            let advertisement = G7Advertisement(name: "DXCM12", manufacturerData: data)
            XCTAssertNil(advertisement.serialChecksum)
            XCTAssertNil(advertisement.isPhoneSlotHeld)
            XCTAssertTrue(advertisement.couldHaveSerial("123456789012"))
        }
    }

    func testNonNumericSerialDoesNotExclude() {
        let advertisement = G7Advertisement(name: "DXCM12", manufacturerData: manufacturerData(serial: "123", typesInUse: 0))
        XCTAssertTrue(advertisement.couldHaveSerial("ABC"))
        XCTAssertNil(G7Advertisement.serialChecksum(for: "ABC"))
        XCTAssertNil(G7Advertisement.serialChecksum(for: ""))
    }

    func testUnsupportedNames() {
        XCTAssertFalse(G7Advertisement(name: "Dexcom12", manufacturerData: nil).isSupportedSensor)
        XCTAssertTrue(G7Advertisement(name: "DX0112", manufacturerData: nil).isSupportedSensor, "Stelo")
        XCTAssertEqual(G7Advertisement(name: "DX0112", manufacturerData: nil).model, .stelo)
        XCTAssertFalse(G7Advertisement(name: "Omnipod", manufacturerData: nil).isSupportedSensor)
    }
}
