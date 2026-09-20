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
    /// Firmware version and serial number, asked for once per sensor right
    /// after the extended version. Only for display.
    public var transmitterVersion: TransmitterVersionMessage?
    public var latestReading: G7GlucoseMessage?
    public var latestReadingTimestamp: Date?
    public var latestConnect: Date?

    /// How readings are obtained from the sensor.
    ///
    /// Restored state written before direct pairing existed has no value
    /// here, and defaulting those to `.eavesdropping` is what keeps an
    /// in-progress session working across the upgrade: the user may not have
    /// the pairing code for a sensor they already applied. Pairing switches
    /// this to `.direct`.
    public var sessionMode: G7SessionMode = .eavesdropping

    /// The 4-digit code printed on the sensor applicator. Direct mode only.
    /// Kept so a stale shared key can be recovered from without asking the
    /// user again, and cleared whenever the sensor is forgotten: it is only
    /// ever valid for the sensor it came with.
    public var pairingCode: String?

    /// The AES key derived by the pairing handshake. Direct mode only; while
    /// it is present, reconnects skip the key exchange.
    ///
    /// This lives in the manager's plist state rather than the keychain,
    /// matching how the rest of this state is persisted. It authenticates a
    /// local Bluetooth link to a disposable sensor and grants nothing beyond
    /// that sensor's own readings.
    public var sharedKey: Data?

    /// The paired sensor's CoreBluetooth identifier, so a relaunch can
    /// retrieve it directly instead of waiting for its next advertisement.
    public var peripheralIdentifier: UUID?

    /// Why the sensor last refused us, and when. Direct mode only. Without
    /// this a refusal (another phone took the sensor's slot, say) is
    /// indistinguishable from signal loss. Cleared by the next reading.
    public var lastAuthenticationFailure: String?
    public var lastAuthenticationFailureDate: Date?

    /// Identifies the sensor and lifetime the session-timed alerts were last
    /// scheduled for. Loop keeps those scheduled notifications across
    /// relaunches, so they are only re-issued when this changes.
    public var lifecycleAlertsScheduledFor: String?

    /// The sensor a failure alert has already been raised for, so it fires
    /// once per sensor rather than on every reading that repeats the state.
    public var sensorFailedAlertIssuedFor: String?

    /// The sensor a `sensorEnd` event has already been recorded for, so the
    /// session is closed in Loop's history exactly once.
    public var sensorEndRecordedFor: String?

    /// When this app paired with, or began following, the current sensor.
    public var pairedAt: Date?

    /// The current sensor's failure, if it has failed: the algorithm state
    /// that said so, and when it was first seen.
    public var sensorFailureMessage: String?
    public var sensorFailedAt: Date?

    /// The sensor before this one, kept until the next replacement.
    public var previousSensor: G7SensorRecord?

    /// The latest calibration entered for this sensor, and the sensor's last
    /// account of its calibration state. Direct mode only.
    public var calibration: G7CalibrationRecord?
    public var calibrationBounds: G7CalibrationBoundsMessage?
    public var calibrationBoundsDate: Date?

    /// When a suspected session end started its grace period, or nil if none is
    /// pending. Persisted so a grace period survives app termination: the deferred
    /// scan is an in-memory work item, so without this a genuinely ended session
    /// would leave the manager tracking a sensor that will never advertise again.
    public var suspectedSessionEndAt: Date?

    init() {
    }

    /// The subset of this state the sensor session needs to reach its sensor.
    var sensorCredentials: G7SensorCredentials {
        G7SensorCredentials(
            sensorID: sensorID,
            pairingCode: pairingCode,
            sharedKey: sharedKey,
            peripheralIdentifier: peripheralIdentifier
        )
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
        if let transmitterVersionData = rawValue["transmitterVersion"] as? Data {
            transmitterVersion = TransmitterVersionMessage(data: transmitterVersionData)
        }
        self.latestReadingTimestamp = rawValue["latestReadingTimestamp"] as? Date
        self.latestConnect = rawValue["latestConnect"] as? Date
        self.sessionMode = (rawValue["sessionMode"] as? String).flatMap(G7SessionMode.init(rawValue:)) ?? .eavesdropping
        self.pairingCode = rawValue["pairingCode"] as? String
        self.sharedKey = rawValue["sharedKey"] as? Data
        self.peripheralIdentifier = (rawValue["peripheralIdentifier"] as? String).flatMap(UUID.init(uuidString:))
        self.lastAuthenticationFailure = rawValue["lastAuthenticationFailure"] as? String
        self.lastAuthenticationFailureDate = rawValue["lastAuthenticationFailureDate"] as? Date
        self.lifecycleAlertsScheduledFor = rawValue["lifecycleAlertsScheduledFor"] as? String
        self.sensorFailedAlertIssuedFor = rawValue["sensorFailedAlertIssuedFor"] as? String
        self.sensorEndRecordedFor = rawValue["sensorEndRecordedFor"] as? String
        self.pairedAt = rawValue["pairedAt"] as? Date
        self.sensorFailureMessage = rawValue["sensorFailureMessage"] as? String
        self.sensorFailedAt = rawValue["sensorFailedAt"] as? Date
        self.previousSensor = (rawValue["previousSensor"] as? G7SensorRecord.RawValue).flatMap(G7SensorRecord.init(rawValue:))
        self.calibration = (rawValue["calibration"] as? G7CalibrationRecord.RawValue).flatMap(G7CalibrationRecord.init(rawValue:))
        self.calibrationBounds = (rawValue["calibrationBounds"] as? Data).flatMap(G7CalibrationBoundsMessage.init(data:))
        self.calibrationBoundsDate = rawValue["calibrationBoundsDate"] as? Date
        self.suspectedSessionEndAt = rawValue["suspectedSessionEndAt"] as? Date
    }

    public var rawValue: RawValue {
        var rawValue: RawValue = [:]
        rawValue["sensorID"] = sensorID
        rawValue["activatedAt"] = activatedAt
        rawValue["latestReading"] = latestReading?.data
        rawValue["extendedVersion"] = extendedVersion?.data
        rawValue["transmitterVersion"] = transmitterVersion?.data
        rawValue["latestReadingTimestamp"] = latestReadingTimestamp
        rawValue["latestConnect"] = latestConnect
        rawValue["sessionMode"] = sessionMode.rawValue
        rawValue["pairingCode"] = pairingCode
        rawValue["sharedKey"] = sharedKey
        rawValue["peripheralIdentifier"] = peripheralIdentifier?.uuidString
        rawValue["lastAuthenticationFailure"] = lastAuthenticationFailure
        rawValue["lastAuthenticationFailureDate"] = lastAuthenticationFailureDate
        rawValue["lifecycleAlertsScheduledFor"] = lifecycleAlertsScheduledFor
        rawValue["sensorFailedAlertIssuedFor"] = sensorFailedAlertIssuedFor
        rawValue["sensorEndRecordedFor"] = sensorEndRecordedFor
        rawValue["pairedAt"] = pairedAt
        rawValue["sensorFailureMessage"] = sensorFailureMessage
        rawValue["sensorFailedAt"] = sensorFailedAt
        rawValue["previousSensor"] = previousSensor?.rawValue
        rawValue["calibration"] = calibration?.rawValue
        rawValue["calibrationBounds"] = calibrationBounds?.data
        rawValue["calibrationBoundsDate"] = calibrationBoundsDate
        rawValue["suspectedSessionEndAt"] = suspectedSessionEndAt
        return rawValue
    }
}
