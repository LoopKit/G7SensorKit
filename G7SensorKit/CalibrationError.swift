//
//  CalibrationError.swift
//  G7SensorKit
//
//  Created by Pete Schwamb on 11/11/22.
//

import Foundation

enum CalibrationError: Error {
    case unreliableState(CalibrationState)
}

extension CalibrationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unreliableState:
            return LocalizedString("Glucose data is unavailable", comment: "Error description for unreliable state")
        }
    }

    var failureReason: String? {
        switch self {
        case .unreliableState(let state):
            return state.localizedDescription
        }
    }
}


extension CalibrationState {
    public var localizedDescription: String {
        switch self {
        case .known(let state):
            switch state {
            case .needCalibration7, .needCalibration14, .needFirstInitialCalibration, .needSecondInitialCalibration, .calibrationError8, .calibrationError9, .calibrationError10, .calibrationError13:
                return LocalizedString("Sensor needs calibration", comment: "The description of sensor calibration state when sensor needs calibration.")
            case .ok:
                return LocalizedString("Sensor calibration is OK", comment: "The description of sensor calibration state when sensor calibration is ok.")
            case .stopped, .sensorFailure11, .sensorFailure12, .sessionFailure15, .sessionFailure16, .sessionFailure17:
                return LocalizedString("Sensor is stopped", comment: "The description of sensor calibration state when sensor is stopped.")
            case .warmup, .questionMarks:
                return LocalizedString("Sensor is warming up", comment: "The description of sensor calibration state when sensor is warming up.")
            case .expired:
                return LocalizedString("Sensor expired", comment: "The description of sensor calibration state when sensor is expired.")
            }
        case .unknown(let rawValue):
            return String(format: LocalizedString("Sensor is in unknown state %1$d", comment: "The description of sensor calibration state when raw value is unknown. (1: missing data details)"), rawValue)
        }
    }
}
