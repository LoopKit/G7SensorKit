//
//  G7SensorRecord.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// Everything worth remembering about a sensor once it is no longer the
/// current one: identity, how it was paired, when its session ran, what it
/// reported about itself, and how it ended. Kept as `previousSensor` in the
/// manager state, the way the pump plugins keep their previous pod, so a
/// failure can still be looked at after the replacement is on.
public struct G7SensorRecord: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]

    public let sensorID: String
    public let pairingCode: String?
    public let serialNumber: String?
    public let firmwareVersion: String?
    /// When this app paired with, or began following, the sensor.
    public let pairedAt: Date?
    /// The sensor's own session start.
    public let activatedAt: Date?
    /// Session length and warmup the sensor reported, if it did.
    public let sessionLength: TimeInterval?
    public let warmupDuration: TimeInterval?
    /// When this app stopped using the sensor.
    public let endedAt: Date
    /// Why, in the user's terms.
    public let endReason: EndReason
    /// The sensor's own failure state and when it was first seen, if the
    /// session ended in failure.
    public let failureMessage: String?
    public let failedAt: Date?

    public enum EndReason: String {
        case replaced
        case deleted
    }

    public var model: G7SensorModel? {
        G7SensorModel(advertisedName: sensorID)
    }

    public init(
        sensorID: String,
        pairingCode: String?,
        serialNumber: String?,
        firmwareVersion: String?,
        pairedAt: Date?,
        activatedAt: Date?,
        sessionLength: TimeInterval?,
        warmupDuration: TimeInterval?,
        endedAt: Date,
        endReason: EndReason,
        failureMessage: String?,
        failedAt: Date?
    ) {
        self.sensorID = sensorID
        self.pairingCode = pairingCode
        self.serialNumber = serialNumber
        self.firmwareVersion = firmwareVersion
        self.pairedAt = pairedAt
        self.activatedAt = activatedAt
        self.sessionLength = sessionLength
        self.warmupDuration = warmupDuration
        self.endedAt = endedAt
        self.endReason = endReason
        self.failureMessage = failureMessage
        self.failedAt = failedAt
    }

    public init?(rawValue: RawValue) {
        guard let sensorID = rawValue["sensorID"] as? String,
              let endedAt = rawValue["endedAt"] as? Date,
              let endReason = (rawValue["endReason"] as? String).flatMap(EndReason.init(rawValue:))
        else {
            return nil
        }
        self.sensorID = sensorID
        self.endedAt = endedAt
        self.endReason = endReason
        pairingCode = rawValue["pairingCode"] as? String
        serialNumber = rawValue["serialNumber"] as? String
        firmwareVersion = rawValue["firmwareVersion"] as? String
        pairedAt = rawValue["pairedAt"] as? Date
        activatedAt = rawValue["activatedAt"] as? Date
        sessionLength = rawValue["sessionLength"] as? TimeInterval
        warmupDuration = rawValue["warmupDuration"] as? TimeInterval
        failureMessage = rawValue["failureMessage"] as? String
        failedAt = rawValue["failedAt"] as? Date
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "sensorID": sensorID,
            "endedAt": endedAt,
            "endReason": endReason.rawValue
        ]
        raw["pairingCode"] = pairingCode
        raw["serialNumber"] = serialNumber
        raw["firmwareVersion"] = firmwareVersion
        raw["pairedAt"] = pairedAt
        raw["activatedAt"] = activatedAt
        raw["sessionLength"] = sessionLength
        raw["warmupDuration"] = warmupDuration
        raw["failureMessage"] = failureMessage
        raw["failedAt"] = failedAt
        return raw
    }
}
