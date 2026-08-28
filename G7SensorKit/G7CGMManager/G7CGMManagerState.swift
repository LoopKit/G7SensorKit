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
    public var activatedAt: Date?
    public var extendedVersion: ExtendedVersionMessage?
    public var latestReading: G7GlucoseMessage?
    public var latestReadingTimestamp: Date?
    public var latestConnect: Date?
    public var uploadReadings: Bool = true
    /// When a suspected session end started its grace period, or nil if none is
    /// pending. Persisted so a grace period survives app termination: the deferred
    /// scan is an in-memory work item, so without this a genuinely ended session
    /// would leave the manager tracking a sensor that will never advertise again.
    public var suspectedSessionEndAt: Date?

    init() {
    }

    public init(rawValue: RawValue) {
        self.sensorID = rawValue["sensorID"] as? String
        self.activatedAt = rawValue["activatedAt"] as? Date
        if let readingData = rawValue["latestReading"] as? Data {
            latestReading = G7GlucoseMessage(data: readingData)
        }
        if let extendedVersionData = rawValue["extendedVersion"] as? Data {
            extendedVersion = ExtendedVersionMessage(data: extendedVersionData)
        }
        self.latestReadingTimestamp = rawValue["latestReadingTimestamp"] as? Date
        self.latestConnect = rawValue["latestConnect"] as? Date
        self.uploadReadings = rawValue["uploadReadings"] as? Bool ?? true
        self.suspectedSessionEndAt = rawValue["suspectedSessionEndAt"] as? Date
    }

    public var rawValue: RawValue {
        var rawValue: RawValue = [:]
        rawValue["sensorID"] = sensorID
        rawValue["activatedAt"] = activatedAt
        rawValue["latestReading"] = latestReading?.data
        rawValue["extendedVersion"] = extendedVersion?.data
        rawValue["latestReadingTimestamp"] = latestReadingTimestamp
        rawValue["latestConnect"] = latestConnect
        rawValue["uploadReadings"] = uploadReadings
        rawValue["suspectedSessionEndAt"] = suspectedSessionEndAt
        return rawValue
    }
}
