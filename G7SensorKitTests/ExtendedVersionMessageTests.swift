//
//  ExtendedVersionMessageTests.swift
//  G7SensorKit
//
//  Created by Pete Schwamb on 12/31/25.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import G7SensorKit

final class ExtendedVersionMessageTests: XCTestCase {

    func testBasicMessage() {
        let data = Data(hexadecimalString: "5200c0d70d00540600020404ff0c00")!
        let message = ExtendedVersionMessage(data: data)!

        XCTAssertEqual(10.5, message.sessionLength.hours / 24)
        XCTAssertEqual(27, message.warmupDuration.minutes)
        XCTAssertEqual(67371520, message.algorithmVersion)
        XCTAssertEqual(255, message.hardwareVersion)
        XCTAssertEqual(12, message.maxLifetimeDays)
    }

    func test15DayMessage() {
        let data = Data(hexadecimalString: "5200406f1400880e00010a04ff1100")!
        let message = ExtendedVersionMessage(data: data)!

        XCTAssertEqual(15.5, message.sessionLength.hours / 24)
        XCTAssertEqual(62, message.warmupDuration.minutes)
        XCTAssertEqual(67764480, message.algorithmVersion)
        XCTAssertEqual(255, message.hardwareVersion)
        XCTAssertEqual(17, message.maxLifetimeDays)
    }
}
