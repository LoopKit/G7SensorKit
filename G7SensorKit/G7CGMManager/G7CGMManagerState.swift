//
//  G7CGMManagerState.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 9/26/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit


public struct G7CGMManagerState: RawRepresentable, Equatable {
    public typealias RawValue = CGMManager.RawStateValue

    public var sensorID: String?
    public var sensorType: G7SensorType = .unknown
    public var activatedAt: Date?
    public var latestReading: G7GlucoseMessage?
    public var latestReadingTimestamp: Date?
    public var latestConnect: Date?
    public var uploadReadings: Bool = false
    public var isFifteenDaySensor: Bool = false

    init() {
    }

    public init(rawValue: RawValue) {
        self.sensorID = rawValue["sensorID"] as? String
        if let sensorTypeString = rawValue["sensorType"] as? String,
           let sensorType = G7SensorType(rawValue: sensorTypeString) {
            self.sensorType = sensorType
        } else {
            if let sensorID = rawValue["sensorID"] as? String {
                self.sensorType = G7SensorType.detect(from: sensorID, isFifteenDaySensor: rawValue["isFifteenDaySensor"] as? Bool ?? false)
            }
        }
        self.activatedAt = rawValue["activatedAt"] as? Date
        if let readingData = rawValue["latestReading"] as? Data {
            latestReading = G7GlucoseMessage(data: readingData)
        }
        self.latestReadingTimestamp = rawValue["latestReadingTimestamp"] as? Date
        self.latestConnect = rawValue["latestConnect"] as? Date
        self.uploadReadings = rawValue["uploadReadings"] as? Bool ?? false
        self.isFifteenDaySensor = rawValue["isFifteenDaySensor"] as? Bool ?? false
    }

    public var rawValue: RawValue {
        var rawValue: RawValue = [:]
        rawValue["sensorID"] = sensorID
        rawValue["sensorType"] = sensorType.rawValue
        rawValue["activatedAt"] = activatedAt
        rawValue["latestReading"] = latestReading?.data
        rawValue["latestReadingTimestamp"] = latestReadingTimestamp
        rawValue["latestConnect"] = latestConnect
        rawValue["uploadReadings"] = uploadReadings
        rawValue["isFifteenDaySensor"] = isFifteenDaySensor
        return rawValue
    }
}
