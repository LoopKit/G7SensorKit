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

/// The sensor's answer to a calibration: `34 xx result:u8 detail:u8`.
/// Result 0 is accepted (high), 1 accepted (low), 2 rejected with the reason
/// in `detail`, 3 factory calibrated. An acceptance only counts with detail 0.
/// The byte meanings are from xDrip4iOS (DexcomG7CalibrationMessages.swift).
public struct G7CalibrateRxMessage: SensorMessage, Equatable {
    /// `result | detail << 8`, as stored in `G7CalibrationRecord`.
    public let status: UInt16
    public let data: Data

    public var result: UInt8 { UInt8(truncatingIfNeeded: status) }
    public var detail: UInt8 { UInt8(truncatingIfNeeded: status >> 8) }

    public var accepted: Bool {
        G7CalibrateRxMessage.isAccepted(status: status)
    }

    public static func isAccepted(status: UInt16) -> Bool {
        let result = UInt8(truncatingIfNeeded: status)
        let detail = UInt8(truncatingIfNeeded: status >> 8)
        return result <= 1 && detail == 0
    }

    public init?(data: Data) {
        guard data.count >= 4, data[0] == G7Opcode.calibrate.rawValue else {
            return nil
        }
        self.data = data
        status = data[2..<4].to(UInt16.self)
    }
}

/// Why the sensor did not take a calibration, from its reply's status.
public enum G7CalibrationRefusal: Equatable {
    case factoryCalibrated
    case acceptanceError(UInt8)
    case unspecified
    case outsideRange
    case timestampInFuture
    case duplicate
    case earlierThanSessionStart
    case notInOrder
    case alreadyEntered
    case disabled
    case notPermitted
    case calibrationBoundsFailed
    case extremeOutlier
    case stale
    case unknown(result: UInt8, detail: UInt8)

    /// Nil when `status` is an acceptance.
    public init?(status: UInt16) {
        guard !G7CalibrateRxMessage.isAccepted(status: status) else {
            return nil
        }
        let result = UInt8(truncatingIfNeeded: status)
        let detail = UInt8(truncatingIfNeeded: status >> 8)
        switch result {
        case 0, 1:
            self = .acceptanceError(detail)
        case 2:
            let reasons: [G7CalibrationRefusal] = [.unspecified, .outsideRange, .timestampInFuture, .duplicate, .earlierThanSessionStart, .notInOrder, .alreadyEntered, .disabled, .notPermitted, .calibrationBoundsFailed, .extremeOutlier, .stale]
            self = Int(detail) < reasons.count ? reasons[Int(detail)] : .unknown(result: result, detail: detail)
        case 3:
            self = .factoryCalibrated
        default:
            self = .unknown(result: result, detail: detail)
        }
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
/// `32 | status u8 | session u8 | sessionSignature u32 | lastGlucose u16 |
/// lastCalibrationTime u32 | processing u8 | permitted u8 | display u8 |
/// lastProcessingUpdateTime u32`, little-endian, times in sensor seconds.
public struct G7CalibrationBoundsMessage: SensorMessage, Equatable {
    public static let length = 20

    public let status: UInt8
    public let sessionNumber: UInt8
    public let sessionSignature: UInt32
    /// The stored value of the most recent calibration, from any display;
    /// `lastCalibrationTime` is its entry time in sensor seconds. It is not
    /// the sensor's running reading, and can be stale or another display's.
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
