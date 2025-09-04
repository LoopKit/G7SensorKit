//
//  CalibrationState.swift
//  xDripG5
//
//  Created by Nate Racklyeft on 8/6/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation


public enum AlgorithmState: RawRepresentable {
    public typealias RawValue = UInt8

    public enum State: RawValue {
        case stopped = 1
        case warmup = 2
        case excessNoise = 3
        case firstOfTwoBGsNeeded = 4
        case secondOfTwoBGsNeeded = 5
        case ok = 6
        case needsCalibration = 7
        case calibrationError1 = 8
        case calibrationError2 = 9
        case calibrationLinearityFitFailure = 10
        case sensorFailedDuetoCountsAberration = 11
        case sensorFailedDuetoResidualAberration = 12
        case outOfCalibrationDueToOutlier = 13
        case outlierCalibrationRequest = 14
        case sessionExpired = 15
        case sessionFailedDueToUnrecoverableError = 16
        case sessionFailedDueToTransmitterError = 17
        case temporarySensorIssue = 18
        case sensorFailedDueToProgressiveSensorDecline = 19
        case sensorFailedDueToHighCountsAberration = 20
        case sensorFailedDueToLowCountsAberration = 21
        case sensorFailedDueToRestart = 22
        case expired = 24
        case sensorFailed = 25
        case sessionEnded = 26
    }

    case known(State)
    case unknown(RawValue)

    public init(rawValue: RawValue) {
        guard let state = State(rawValue: rawValue) else {
            self = .unknown(rawValue)
            return
        }

        self = .known(state)
    }

    public var rawValue: RawValue {
        switch self {
        case .known(let state):
            return state.rawValue
        case .unknown(let rawValue):
            return rawValue
        }
    }

    public var sensorFailed: Bool {
        guard case .known(let state) = self else {
            return false
        }

        switch state {
        case .sensorFailed, .sensorFailedDuetoCountsAberration, .sensorFailedDuetoResidualAberration, .sessionFailedDueToTransmitterError, .sessionFailedDueToUnrecoverableError, .sensorFailedDueToProgressiveSensorDecline, .sensorFailedDueToHighCountsAberration, .sensorFailedDueToLowCountsAberration, .sensorFailedDueToRestart:
            return true
        default:
            return false
        }
    }

    public var isInWarmup: Bool {
        guard case .known(let state) = self else {
            return false
        }

        switch state {
        case .warmup:
            return true
        default:
            return false
        }
    }

    public var hasTemporaryError: Bool {
        guard case .known(let state) = self else {
            return false
        }

        switch state {
        case .temporarySensorIssue:
            return true
        default:
            return false
        }
    }


    public var hasReliableGlucose: Bool {
        guard case .known(let state) = self else {
            return false
        }

        switch state {
        case .ok:
            return true
        default:
            return false
        }
    }
}

extension AlgorithmState: Equatable {
    public static func ==(lhs: AlgorithmState, rhs: AlgorithmState) -> Bool {
        switch (lhs, rhs) {
        case (.known(let lhs), .known(let rhs)):
            return lhs == rhs
        case (.unknown(let lhs), .unknown(let rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}

extension AlgorithmState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .known(let state):
            return String(describing: state)
        case .unknown(let value):
            return ".unknown(\(value))"
        }
    }
}
