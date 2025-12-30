//
//  G7SensorType.swift
//  G7SensorKit
//
//  Created by Daniel Johansson on 12/19/24.
//  Copyright © 2024 LoopKit Authors. All rights reserved.
//

import Foundation

public enum G7SensorType: String, CaseIterable, CustomStringConvertible {
    case g7 = "G7"
    case g7extended = "G7 Extended"
    case onePlus = "ONE+"
    case stelo = "Stelo"
    case unknown = "Unknown"
    
    public var description: String {
        switch self {
        case .g7:
            return "Dexcom G7"
        case .g7extended:
            return "Dexcom G7 Extended"
        case .onePlus:
            return "Dexcom ONE+"
        case .stelo:
            return "Dexcom Stelo"
        case .unknown:
            return "Unknown Sensor"
        }
    }
    
    public var displayName: String {
        return description
    }
    
    public var lifetime: TimeInterval {
        switch self {
        case .g7:
            return TimeInterval(hours: 10 * 24) // 10 days
        case .g7extended:
            return TimeInterval(hours: 15 * 24) // 15 days
        case .onePlus:
            return TimeInterval(hours: 10 * 24) // 10 days
        case .stelo:
            return TimeInterval(hours: 15 * 24) // 15 days
        case .unknown:
            return TimeInterval(hours: 10 * 24) // Default to 10 days
        }
    }
    
    public var gracePeriod: TimeInterval {
        switch self {
        case .g7, .g7extended, .onePlus, .stelo, .unknown:
            return TimeInterval(hours: 12) // 12 hours for all
        }
    }
    
    public var warmupDuration: TimeInterval {
        switch self {
        case .g7, .onePlus, .stelo, .unknown:
            return TimeInterval(minutes: 25) // 25 minutes for all other
        case .g7extended:
            return TimeInterval(minutes: 60) // 60 minutes for extended
        }
    }
    public var totalLifetimeHours: Double {
        return (lifetime + gracePeriod).hours
    }
    
    public var warmupHours: Double {
        return warmupDuration.hours
    }
    
    public var dexcomAppURL: String {
        switch self {
        case .g7, .g7extended:
            return "dexcomg7://"
        case .onePlus:
            return "dexcomg7://" // ONE+ Uses same URL as G7 app. If G7 and One+ is installed, the G7 app will open
        case .stelo:
            return "stelo://"
        case .unknown:
            return "dexcomg7://" // Default to G7 app
        }
    }
    
    /// Detects sensor type based on the sensor name/ID
    public static func detect(from sensorName: String, isFifteenDaySensor: Bool) -> G7SensorType {
        let name = sensorName.uppercased()
        if name.hasPrefix("DXCM") {
            if isFifteenDaySensor {
                return .g7extended
            }
            return .g7
        } else if name.hasPrefix("DX01") {
            return .stelo
        } else if name.hasPrefix("DX02") {
            return .onePlus
        } else {
            return .unknown
        }
    }

    public static func forFifteenDayOption(baseType: G7SensorType, isFifteenDaySensor: Bool) -> G7SensorType {
        switch baseType {
        case .g7:
            return isFifteenDaySensor ? .g7extended : .g7
        default:
            return baseType
        }
    }
}
