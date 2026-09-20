//
//  G7Opcode.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 9/24/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation

enum G7Opcode: UInt8 {
    case authChallengeRx = 0x05

    /// Drops the BLE link for this connection cycle. Not session teardown:
    /// that is `sessionStopTx`, which we deliberately never send.
    case disconnect = 0x09
    case sessionStopTx = 0x28
    /// The sensor's calibration state; see `G7CalibrationBoundsMessage`.
    case calibrationBounds = 0x32
    /// A meter glucose for the sensor to calibrate to; see `G7CalibrateTxMessage`.
    case calibrate = 0x34
    /// Firmware version and serial number; see `TransmitterVersionMessage`.
    case transmitterVersion = 0x4a
    case glucoseTx = 0x4e
    case extendedVersionTx = 0x52
    case extendedVersionRx = 0x53
    case backfillFinished = 0x59
}
