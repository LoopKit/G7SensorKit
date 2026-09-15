//
//  G7CalibrationRecord.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// The most recent calibration entered for the current sensor and what
/// became of it. The sensor is the source of truth (`G7CalibrationBoundsMessage`);
/// this is what the settings screen shows while that plays out.
public struct G7CalibrationRecord: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]

    public enum Outcome: Equatable {
        /// Queued for the sensor's next connection, or sent and unanswered.
        case pending
        case accepted(at: Date)
        case rejected(status: UInt16, at: Date)
    }

    /// The meter value, mg/dL.
    public let glucose: UInt16
    public let enteredAt: Date
    public var outcome: Outcome
    /// From the bounds answers that follow an accepted calibration.
    public var processingStatus: G7CalibrationProcessingStatus?

    public init(glucose: UInt16, enteredAt: Date, outcome: Outcome = .pending, processingStatus: G7CalibrationProcessingStatus? = nil) {
        self.glucose = glucose
        self.enteredAt = enteredAt
        self.outcome = outcome
        self.processingStatus = processingStatus
    }

    public init?(rawValue: RawValue) {
        guard let glucose = rawValue["glucose"] as? UInt16 ?? (rawValue["glucose"] as? Int).map(UInt16.init),
              let enteredAt = rawValue["enteredAt"] as? Date,
              let outcomeName = rawValue["outcome"] as? String
        else {
            return nil
        }
        self.glucose = glucose
        self.enteredAt = enteredAt
        switch outcomeName {
        case "accepted":
            guard let at = rawValue["outcomeAt"] as? Date else { return nil }
            outcome = .accepted(at: at)
        case "rejected":
            guard let at = rawValue["outcomeAt"] as? Date, let status = rawValue["status"] as? Int else { return nil }
            outcome = .rejected(status: UInt16(truncatingIfNeeded: status), at: at)
        default:
            outcome = .pending
        }
        processingStatus = (rawValue["processingStatus"] as? Int).map { G7CalibrationProcessingStatus(byte: UInt8(truncatingIfNeeded: $0)) }
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "glucose": Int(glucose),
            "enteredAt": enteredAt,
        ]
        switch outcome {
        case .pending:
            raw["outcome"] = "pending"
        case .accepted(let at):
            raw["outcome"] = "accepted"
            raw["outcomeAt"] = at
        case .rejected(let status, let at):
            raw["outcome"] = "rejected"
            raw["outcomeAt"] = at
            raw["status"] = Int(status)
        }
        raw["processingStatus"] = processingStatus.map { Int($0.rawValue) }
        return raw
    }
}
