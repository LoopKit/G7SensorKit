//
//  G7SettingsViewModel.swift
//  CGMBLEKitUI
//
//  Created by Pete Schwamb on 10/4/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import G7SensorKit
import LoopAlgorithm
import LoopKit
import LoopKitUI

public enum ColorStyle {
    case glucose, warning, critical, normal, dimmed
}

class G7SettingsViewModel: ObservableObject {
    @Published private(set) var scanning: Bool = false
    @Published private(set) var connected: Bool = false
    @Published private(set) var sensorName: String?
    @Published private(set) var activatedAt: Date?
    @Published private(set) var lastConnect: Date?
    @Published private(set) var lifetime: TimeInterval
    @Published private(set) var warmupDuration: TimeInterval
    @Published private(set) var latestReadingTimestamp: Date?
    @Published private(set) var sessionMode: G7SessionMode = .eavesdropping
    @Published private(set) var isDexcomAppInstalled: Bool = false
    @Published private(set) var lifecycleState: G7SensorLifecycleState = .searching
    @Published private(set) var title: String = ""
    @Published private(set) var pairedAt: Date?
    @Published private(set) var previousSensor: G7SensorRecord?
    @Published private(set) var lastGlucoseTrend: GlucoseTrend?
    @Published private(set) var sensorEndsAt: Date?
    @Published private(set) var sensorModel: G7SensorModel = .g7
    /// "G7 15 Day" once the sensor has said, "G7" before.
    @Published private(set) var sensorModelName: String = ""
    @Published private(set) var pairingCode: String?
    @Published private(set) var serialNumber: String?
    @Published private(set) var firmwareVersion: String?
    @Published private(set) var softwareNumber: String?
    @Published private(set) var siliconVersion: String?
    @Published private(set) var hardwareVersion: String?
    @Published private(set) var algorithmVersion: String?
    /// Whether the sensor has reported its lifetime; until then the defaults
    /// are in use and not worth presenting as the sensor's own.
    @Published private(set) var hasReportedLifetime: Bool = false
    @Published private(set) var lastAuthenticationFailure: String?
    @Published private(set) var lastAuthenticationFailureDate: Date?
    @Published private(set) var calibration: G7CalibrationRecord?
    @Published private(set) var calibrationBounds: G7CalibrationBoundsMessage?
    @Published private(set) var hasPendingCalibration: Bool = false
    @Published private(set) var canCalibrate: Bool = false
    
    let displayGlucosePreference: DisplayGlucosePreference

    private var lastReading: G7GlucoseMessage?

    lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private var cgmManager: G7CGMManager

    var progressBarState: G7ProgressBarState {
        switch cgmManager.lifecycleState {
        case .searching, .unpaired:
            return .searchingForSensor
        case .connecting:
            return .connecting
        case .ok:
            return .lifetimeRemaining
        case .warmup:
            return .warmupProgress
        case .failed:
            return .sensorFailed
        case .gracePeriod:
            return .gracePeriodRemaining
        case .expired:
            return .sensorExpired
        }
    }

    init(cgmManager: G7CGMManager, displayGlucosePreference: DisplayGlucosePreference) {
        self.cgmManager = cgmManager
        self.displayGlucosePreference = displayGlucosePreference
        self.lifetime = cgmManager.lifetime
        self.warmupDuration = cgmManager.warmupDuration
        updateValues()
        // Once per visit to settings: which Dexcom apps the phone admits to.
        cgmManager.logDeviceCommunication("Dexcom app probe: " + G7DexcomApp.describeProbe(), type: .connection)

        self.cgmManager.addStateObserver(self, queue: DispatchQueue.main)
    }

    func updateValues() {
        scanning = cgmManager.isScanning
        sensorName = cgmManager.sensorName
        activatedAt = cgmManager.sensorActivatedAt
        connected = cgmManager.isConnected
        lastConnect = cgmManager.lastConnect
        lastReading = cgmManager.latestReading
        latestReadingTimestamp = cgmManager.latestReadingTimestamp
        lifetime = cgmManager.lifetime
        warmupDuration = cgmManager.warmupDuration
        sessionMode = cgmManager.sessionMode
        isDexcomAppInstalled = G7DexcomApp.isAnyInstalled
        lifecycleState = cgmManager.lifecycleState
        title = cgmManager.localizedTitle
        pairedAt = cgmManager.state.pairedAt
        previousSensor = cgmManager.state.previousSensor
        lastGlucoseTrend = cgmManager.latestReading?.hasReliableGlucose == true ? cgmManager.latestReading?.trendType : nil
        sensorEndsAt = cgmManager.sensorEndsAt
        sensorModel = cgmManager.sensorModel
        sensorModelName = cgmManager.sensorModel.displayName(sessionLength: cgmManager.state.extendedVersion?.sessionLength)
        pairingCode = cgmManager.state.pairingCode
        serialNumber = cgmManager.state.transmitterVersion?.serialNumberString
        firmwareVersion = cgmManager.state.transmitterVersion?.firmwareVersion
        softwareNumber = cgmManager.state.transmitterVersion.map { String($0.softwareNumber) }
        siliconVersion = cgmManager.state.transmitterVersion.map { String($0.siliconVersion) }
        hardwareVersion = cgmManager.state.extendedVersion.map { String($0.hardwareVersion) }
        algorithmVersion = cgmManager.state.extendedVersion.map { String($0.algorithmVersion) }
        hasReportedLifetime = cgmManager.state.extendedVersion != nil
        lastAuthenticationFailure = cgmManager.state.lastAuthenticationFailure
        lastAuthenticationFailureDate = cgmManager.state.lastAuthenticationFailureDate
        calibration = cgmManager.calibration
        calibrationBounds = cgmManager.state.calibrationBounds
        hasPendingCalibration = cgmManager.hasPendingCalibration
        canCalibrate = cgmManager.canCalibrate
    }

    // MARK: - Calibration

    /// The last reliable reading in mg/dL, for the calibration entry to
    /// compare against.
    var lastGlucoseMgdl: Double? {
        guard let lastReading = lastReading, lastReading.hasReliableGlucose, let quantity = lastReading.glucoseQuantity else {
            return nil
        }
        return quantity.doubleValue(for: .milligramsPerDeciliter)
    }

    /// The last trend in mg/dL/min, for the "is glucose stable" check.
    var lastTrendMgdlPerMinute: Double? {
        guard let lastReading = lastReading, lastReading.hasReliableGlucose else {
            return nil
        }
        return lastReading.trend
    }

    var glucoseUnit: LoopUnit {
        displayGlucosePreference.unit
    }

    var glucoseUnitString: String {
        displayGlucosePreference.formatter.localizedUnitStringWithPlurality()
    }

    func formatGlucose(mgdl: Double, includeUnit: Bool = true) -> String {
        displayGlucosePreference.format(LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: mgdl), includeUnit: includeUnit)
    }

    /// A value typed in the display unit, as mg/dL.
    func mgdl(fromDisplayValue value: Double) -> Double {
        LoopQuantity(unit: displayGlucosePreference.unit, doubleValue: value).doubleValue(for: .milligramsPerDeciliter)
    }

    func calibrate(mgdl: Double) {
        cgmManager.calibrate(glucose: UInt16(mgdl.rounded()))
        updateValues()
    }

    func cancelPendingCalibration() {
        cgmManager.cancelPendingCalibration()
        updateValues()
    }

    /// Whether the session has run its course and the next thing to do is
    /// put on and pair a new sensor.
    var needsNewSensor: Bool {
        switch lifecycleState {
        case .expired, .failed, .gracePeriod, .unpaired:
            return true
        case .searching, .connecting, .warmup, .ok:
            return false
        }
    }

    /// Re-check things that change outside the manager, such as the Dexcom
    /// app being deleted while this screen was in the background.
    func refreshEnvironment() {
        isDexcomAppInstalled = G7DexcomApp.isAnyInstalled
    }

    var progressBarColorStyle: ColorStyle {
        switch progressBarState {
        case .warmupProgress:
            return .glucose
        case .searchingForSensor, .connecting:
            return .dimmed
        case .sensorExpired, .sensorFailed:
            return .critical
        case .lifetimeRemaining:
            guard let remaining = progressValue else {
                return .dimmed
            }
            if remaining > .hours(24) {
                return .glucose
            } else {
                return .warning
            }
        case .gracePeriodRemaining:
            return .critical
        }
    }

    var progressBarProgress: Double {
        switch progressBarState {
        case .searchingForSensor, .connecting:
            return 0
        case .warmupProgress:
            guard let value = progressValue, value > 0 else {
                return 0
            }
            return 1 - value / warmupDuration
        case .lifetimeRemaining:
            guard let value = progressValue, value > 0 else {
                return 0
            }
            return 1 - value / lifetime
        case .gracePeriodRemaining:
            guard let value = progressValue, value > 0 else {
                return 0
            }
            return 1 - value / G7Sensor.gracePeriod
        case .sensorExpired, .sensorFailed:
            return 1
        }
    }

    var progressReferenceDate: Date? {
        switch progressBarState {
        case .searchingForSensor, .connecting:
            return nil
        case .sensorExpired, .gracePeriodRemaining:
            return cgmManager.sensorEndsAt
        case .warmupProgress:
            return cgmManager.sensorFinishesWarmupAt
        case .lifetimeRemaining:
            return cgmManager.sensorExpiresAt
        case .sensorFailed:
            return nil
        }
    }

    var progressValue: TimeInterval? {
        switch progressBarState {
        case .sensorExpired, .sensorFailed, .searchingForSensor, .connecting:
            guard let sensorEndsAt = cgmManager.sensorEndsAt else {
                return nil
            }
            return sensorEndsAt.timeIntervalSinceNow
        case .warmupProgress:
            guard let warmupFinishedAt = cgmManager.sensorFinishesWarmupAt else {
                return nil
            }
            return max(0, warmupFinishedAt.timeIntervalSinceNow)
        case .lifetimeRemaining:
            guard let expiration = cgmManager.sensorExpiresAt else {
                return nil
            }
            return max(0, expiration.timeIntervalSinceNow)
        case .gracePeriodRemaining:
            guard let sensorEndsAt = cgmManager.sensorEndsAt else {
                return nil
            }
            return max(0, sensorEndsAt.timeIntervalSinceNow)
        }
    }

    func scanForNewSensor() {
        cgmManager.scanForNewSensor()
    }

    /// Whether the last reading carries a glucose value worth showing.
    var hasLastGlucose: Bool {
        guard let lastReading = lastReading, lastReading.hasReliableGlucose else {
            return false
        }
        return lastReading.glucoseQuantity != nil
    }

    /// The last glucose without its unit, for a layout that sets the unit
    /// separately. LOW/HIGH stand in for out-of-range values as usual.
    var lastGlucoseValueString: String {
        guard let lastReading = lastReading, lastReading.hasReliableGlucose, let quantity = lastReading.glucoseQuantity else {
            return LocalizedString("– – –", comment: "No glucose value representation (3 dashes for mg/dL)")
        }

        switch lastReading.glucoseRangeCategory {
        case .some(.belowRange):
            return LocalizedString("LOW", comment: "String displayed instead of a glucose value below the CGM range")
        case .some(.aboveRange):
            return LocalizedString("HIGH", comment: "String displayed instead of a glucose value above the CGM range")
        default:
            return displayGlucosePreference.formatter.string(from: quantity, includeUnit: false) ?? ""
        }
    }

    var lastGlucoseString: String {
        guard let lastReading = lastReading, lastReading.hasReliableGlucose, let quantity = lastReading.glucoseQuantity else {
            return LocalizedString("– – –", comment: "No glucose value representation (3 dashes for mg/dL)")
        }

        switch lastReading.glucoseRangeCategory {
        case .some(.belowRange):
            return LocalizedString("LOW", comment: "String displayed instead of a glucose value below the CGM range")
        case .some(.aboveRange):
            return LocalizedString("HIGH", comment: "String displayed instead of a glucose value above the CGM range")
        default:
            return displayGlucosePreference.formatter.string(from: quantity)!
        }
    }

    var lastGlucoseTrendString: String {
        if let lastReading = lastReading, lastReading.hasReliableGlucose, let trendRate = lastReading.trendRate {
            return displayGlucosePreference.formatMinuteRate(trendRate)
        } else {
            return ""
        }
    }
}

extension G7SettingsViewModel: G7StateObserver {
    func g7StateDidUpdate(_ state: G7CGMManagerState?) {
        updateValues()
    }

    func g7ConnectionStatusDidChange() {
        updateValues()
    }
}
