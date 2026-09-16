//
//  TransmitterVersionMessageTests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import G7SensorKit

class TransmitterVersionMessageTests: XCTestCase {

    func testSyntheticLayout() throws {
        // 4A | status 00 | version 25 c0 69 5e | sw 04030201 | silicon ddccbbaa | serial 060504030201
        let message = try XCTUnwrap(TransmitterVersionMessage(data: Data(hexadecimalString: "4a0025c0695e04030201ddccbbaa060504030201")!))
        XCTAssertEqual(message.status, 0)
        XCTAssertEqual(message.firmwareVersion, "37.192.105.94")
        XCTAssertEqual(message.softwareNumber, 0x0102_0304)
        XCTAssertEqual(message.siliconVersion, 0xAABB_CCDD)
        XCTAssertEqual(message.serialNumber, 0x0102_0304_0506)
    }

    /// A reply captured from a sensor.
    func testCapturedReply() throws {
        let message = try XCTUnwrap(TransmitterVersionMessage(data: Data(hexadecimalString: "4a002cc069489c37000031474141c03e55bcb300")!))
        XCTAssertEqual(message.firmwareVersion, "44.192.105.72")
        XCTAssertEqual(message.softwareNumber, 0x0000_379C)
        XCTAssertEqual(message.serialNumberString, String(0x00B3_BC55_3EC0 as UInt64))
    }

    func testRejectsOtherOpcodesAndShortReplies() {
        XCTAssertNil(TransmitterVersionMessage(data: Data(hexadecimalString: "4e0025c0695e04030201ddccbbaa060504030201")!))
        XCTAssertNil(TransmitterVersionMessage(data: Data(hexadecimalString: "4a0025c0695e04030201ddccbbaa0605040302")!))
    }

    func testRoundTripsThroughState() {
        var state = G7CGMManagerState()
        state.transmitterVersion = TransmitterVersionMessage(data: Data(hexadecimalString: "4a002cc069489c37000031474141c03e55bcb300")!)
        let restored = G7CGMManagerState(rawValue: state.rawValue)
        XCTAssertEqual(restored.transmitterVersion, state.transmitterVersion)
        XCTAssertEqual(restored.transmitterVersion?.firmwareVersion, "44.192.105.72")
    }
}
