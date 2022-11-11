//
//  G7LifecycleBarViewModel.swift
//  CGMBLEKitUI
//
//  Created by Pete Schwamb on 10/23/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import G7SensorKit

public enum ColorStyle {
    case glucose, warning, critical, normal, dimmed
}

public struct G7LifecycleBarViewModel {

    private enum ProgressBarState {
        case inWarmup
        case noSensor
        case sensorExpired
        case sensorExpiringIn24Hrs
        case sensorFailure
        case sensorTemporaryError
        case sessionInProgress
        case sessionIsStarting
        case transmitterFailure
    }

    private let sessionExpirationDate: Date?
    private let sessionStartDate: Date?
    private let warmupCompletionDate: Date?
    private let sensorFailureDate: Date?
    private let calibrationState: CalibrationState?
    private let isStartingSession: Bool
    private let isSessionRunning: Bool

    private let calendar = Calendar.current
    private let sessionExpirationTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .medium
        formatter.formattingContext = .middleOfSentence
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    public init(sessionExpirationDate: Date?, sessionStartDate: Date?, warmupCompletionDate: Date?, sensorFailureDate: Date?, calibrationState: CalibrationState?, isStartingSession: Bool, isSessionRunning: Bool) {
        self.sessionExpirationDate = sessionExpirationDate
        self.sessionStartDate = sessionStartDate
        self.warmupCompletionDate = warmupCompletionDate
        self.sensorFailureDate = sensorFailureDate
        self.calibrationState = calibrationState
        self.isStartingSession = isStartingSession
        self.isSessionRunning = isSessionRunning
    }

    private func progressBarState(asOf now: Date) -> ProgressBarState {
        if isStartingSession {
            return .sessionIsStarting
        }
        if isInSensorFailure {
            return .sensorFailure
        }
        if isInWarmup {
            return .inWarmup
        }
        if hasSensorTemporaryError {
            return .sensorTemporaryError
        }
        if isSessionRunning {
            return .sessionInProgress
        }
        return .noSensor
    }

    public func progressBarLabel(now: Date) -> String {
        switch progressBarState(asOf: now) {
        case .sessionIsStarting, .inWarmup, .noSensor:
            return LocalizedString("Warmup completes in", comment: "Sensor expiration label (warming up or about to warm up)")
        case .sessionInProgress, .sensorExpiringIn24Hrs:
            return LocalizedString("Sensor expires in", comment: "Sensor expiration label (expiration in the future)")
        case .sensorFailure, .sensorTemporaryError, .transmitterFailure:
            if let warmupCompletionDate = warmupCompletionDate,
               warmupCompletionDate > now
            {
                return LocalizedString("Warmup completes in", comment: "Sensor expiration label (warming up or about to warm up)")
            } else {
                return LocalizedString("Sensor expires in", comment: "Sensor expiration label (expiration in the future)")
            }
        case .sensorExpired:
            return String(format: LocalizedString("Sensor expired%@", comment: "Sensor expiration label (sensor expired) (1: sensor expiration date, might be \"\")"),
                          // Don't show date if it isn't actually expired
                          sensorHasExpired(now: now) ?
                          sessionExpirationDate.map { " " + sessionExpirationTimeFormatter.string(from: $0) } ?? "" :
                          "")
        }
    }

    public func progressBarLabelColor(now: Date) -> ColorStyle {
        switch progressBarState(asOf: now) {
        case .sessionIsStarting, .inWarmup, .sessionInProgress, .sensorExpiringIn24Hrs, .noSensor, .sensorFailure, .transmitterFailure, .sensorTemporaryError:
            return .dimmed
        case .sensorExpired:
            return .critical
        }
    }

    public func progressBarProgress(now: Date) -> Double {
        switch progressBarState(asOf: now) {
        case .sessionIsStarting:
            return 0
        case .inWarmup:
            return warmupProgress(now: now)
        case .sessionInProgress, .sensorExpiringIn24Hrs:
            return sessionProgress(now: now)
        case .sensorFailure, .sensorTemporaryError, .transmitterFailure:
            if let warmupCompletionDate = warmupCompletionDate,
               warmupCompletionDate > now
            {
                return warmupProgress(now: now)
            } else {
                return sessionProgress(now: now)
            }
        case .sensorExpired:
            return 1.0
        case .noSensor:
            return 0
        }
    }

    private func warmupProgress(now: Date) -> Double {
        guard let sessionStartDate = sessionStartDate,
              let warmupCompletionDate = warmupCompletionDate else {
            return 0
        }
        let timeSinceStarted = max(0.0, now.timeIntervalSince(sessionStartDate))
        let timeUntilWarmup = warmupCompletionDate.timeIntervalSince(sessionStartDate)
        if timeUntilWarmup > 0 {
            return min(1.0, timeSinceStarted / timeUntilWarmup)
        } else {
            return 0
        }
    }

    private func sessionProgress(now: Date) -> Double {
        guard let sessionStartDate = sessionStartDate,
              let sessionExpirationDate = sessionExpirationDate else {
            return 0
        }
        let progressTimeSinceStarted = max(0.0, progressPoint(from: now).timeIntervalSince(sessionStartDate))
        let timeUntilExpiration = sessionExpirationDate.timeIntervalSince(sessionStartDate)
        if timeUntilExpiration > 0 {
            return min(1.0, progressTimeSinceStarted / timeUntilExpiration)
        } else {
            return 0
        }
    }

    private func progressPoint(from now: Date) -> Date {
        if let sensorFailureDate = sensorFailureDate {
            return sensorFailureDate
        } else {
            return now
        }
    }

    public func progressBarColorStyle(now: Date) -> ColorStyle {
        switch progressBarState(asOf: now) {
        case .inWarmup:
            return .glucose
        case .noSensor:
            return .dimmed
        case .sensorExpired:
            return .critical
        case .sensorExpiringIn24Hrs:
            return .warning
        case .sensorFailure:
            return .dimmed
        case .sensorTemporaryError:
            return .glucose
        case .sessionInProgress:
            return .glucose
        case .sessionIsStarting:
            return .dimmed
        case .transmitterFailure:
            return .dimmed
        }
    }
}


extension G7LifecycleBarViewModel {

    private var isInSensorFailure: Bool {
        return calibrationState?.sensorFailed ?? false
    }

    private var isInWarmup: Bool {
        return calibrationState?.isInWarmup ?? false
    }

    private func sensorHasExpired(now: Date) -> Bool {
        guard let sessionExpirationDate = sessionExpirationDate else { return false }
        return sessionExpirationDate < now
    }

    private var hasSensorTemporaryError: Bool {
        return calibrationState?.isInSensorError ?? false
    }

}
