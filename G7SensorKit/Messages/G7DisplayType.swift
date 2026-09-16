//
//  G7DisplayType.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  The type values are from DexKit by Erik Tolboom
//  (https://github.com/nightscout/DexKit), from the official app.
//

import Foundation

/// What kind of display a sensor is talking to. A sensor keeps one slot per
/// display type, so a phone and a watch can both hold a session with it,
/// while two phones cannot. Sent in the authentication challenge, reported
/// in the calibration state, and the advertisement's types-in-use byte says
/// which types currently hold a slot.
public enum G7DisplayType: UInt8, CaseIterable {
    case unknown = 0
    case medical = 1
    case phone = 2
    case watch = 3
    case receiver = 4
    case pump = 5
    case reader = 6
    case tool = 7
    case other = 8
    case transmitter = 9

    /// This type's bit in the advertisement's types-in-use byte. The phone's
    /// is 0x02 by observation; the rest follow the same pattern by inference
    /// and have not been seen on the air.
    public var typesInUseMask: UInt8 {
        guard rawValue > 0, rawValue <= 8 else { return 0 }
        return 1 << (rawValue - 1)
    }
}
