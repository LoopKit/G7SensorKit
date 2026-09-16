//
//  G7CalibrationMessage.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  The processing-status values and the bounds message layout are from DexKit
//  by Erik Tolboom (https://github.com/nightscout/DexKit).
//

import Foundation

/// Calibrate (0x34): a meter glucose and when it was taken, on the sensor's
/// seconds-since-activation clock.
public struct G7CalibrateTxMessage: Equatable {
    public let glucose: UInt16
    public let sensorAge: UInt32

    public init(glucose: UInt16, sensorAge: UInt32) {
        self.glucose = glucose
        self.sensorAge = sensorAge
    }

    public var data: Data {
        var data = Data([G7Opcode.calibrate.rawValue])
        data.append(glucose)
        data.append(sensorAge)
        return data
    }
}

/// The sensor's answer to a calibration: `34 xx status:u16`. 1 is accepted;
/// anything else is a refusal (warmup, or a value it will not take).
public struct G7CalibrateRxMessage: SensorMessage, Equatable {
    public static let acceptedStatus: UInt16 = 1

    public let status: UInt16
    public let data: Data

    public var accepted: Bool {
        status == G7CalibrateRxMessage.acceptedStatus
    }

    public init?(data: Data) {
        guard data.count >= 4, data[0] == G7Opcode.calibrate.rawValue else {
            return nil
        }
        self.data = data
        status = data[2..<4].to(UInt16.self)
    }
}

/// What the sensor has done with its calibration, from the bounds answer.
/// Observed 2026-09-15: a calibration accepted right after a reading was
/// `inProgress` on that connection and the next, and `completeHigh` on the
/// second reading after it, about ten minutes later.
public enum G7CalibrationProcessingStatus: UInt8 {
    case none = 0
    case factoryCalibrated = 1
    case inProgress = 2
    case completeHigh = 3
    case completeLow = 4
    case unknown = 255

    public init(byte: UInt8) {
        self = G7CalibrationProcessingStatus(rawValue: byte) ?? .unknown
    }
}

/// Calibration Bounds (0x32): the sensor's calibration state. 20 bytes:
/// `32 | status u8 | session u8 | sessionSignature u32 | lastEGV u16 |
/// lastCalibrationTime u32 | processing u8 | permitted u8 | display u8 |
/// lastProcessingUpdateTime u32`, little-endian, times in sensor seconds.
public struct G7CalibrationBoundsMessage: SensorMessage, Equatable {
    public static let length = 20

    public let status: UInt8
    public let sessionNumber: UInt8
    public let sessionSignature: UInt32
    /// The meter value of the last calibration (entered 145, read back 145
    /// with the same sensor-seconds stamp, 2026-09-15).
    public let lastGlucose: UInt16
    /// Sensor seconds; 0 when the sensor has never been calibrated.
    public let lastCalibrationTime: UInt32
    public let processingStatus: G7CalibrationProcessingStatus
    public let calibrationsPermitted: Bool
    public let lastDisplayType: G7DisplayType
    public let lastProcessingUpdateTime: UInt32
    public let data: Data

    public var hasCalibration: Bool {
        lastCalibrationTime > 0
    }

    public init?(data: Data) {
        guard data.count >= G7CalibrationBoundsMessage.length, data[0] == G7Opcode.calibrationBounds.rawValue else {
            return nil
        }
        self.data = data
        status = data[1]
        sessionNumber = data[2]
        sessionSignature = data[3..<7].to(UInt32.self)
        lastGlucose = data[7..<9].to(UInt16.self)
        lastCalibrationTime = data[9..<13].to(UInt32.self)
        processingStatus = G7CalibrationProcessingStatus(byte: data[13])
        calibrationsPermitted = data[14] == 1
        lastDisplayType = G7DisplayType(rawValue: data[15]) ?? .unknown
        lastProcessingUpdateTime = data[16..<20].to(UInt32.self)
    }
}

extension G7CalibrationBoundsMessage: CustomStringConvertible {
    public var description: String {
        "G7CalibrationBoundsMessage(lastGlucose:\(lastGlucose) at:\(lastCalibrationTime)s processing:\(processingStatus) permitted:\(calibrationsPermitted) display:\(lastDisplayType) data:\(data.hexadecimalString))"
    }
}
