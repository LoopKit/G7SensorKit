//
//  G7SettingsViewModel.swift
//  CGMBLEKitUI
//
//  Created by Pete Schwamb on 10/4/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import CGMBLEKit
import LoopKit

enum G7ProgressBarState {
    case warmupProgress
    case expirationProgress
    case sensorFailed
    case sensorExpired
    case searchingForSensor

    init(lifecycle: G7SensorLifecycleState) {
        switch lifecycle {
        case .searching:
            self = .searchingForSensor
        case .error, .ok:
            self = .expirationProgress
        case .warmup:
            self = .warmupProgress
        case .failed:
            self = .sensorFailed
        case .expired:
            self = .sensorExpired

        }
    }

    var label: String {
        switch self {
        case .searchingForSensor:
            return LocalizedString("Searching for sensor", comment: "G7 Progress bar label when searching for sensor")
        case .sensorExpired:
            return LocalizedString("Sensor expired", comment: "G7 Progress bar label when sensor expired")
        case .warmupProgress:
            return LocalizedString("Warmup completes in", comment: "G7 Progress bar label when sensor in warmup")
        case .sensorFailed:
            return LocalizedString("Sensor failed", comment: "G7 Progress bar label when sensor failed")
        case .expirationProgress:
            return LocalizedString("Sensor expires in", comment: "G7 Progress bar label when sensor failed")
        }
    }

    var labelColor: ColorStyle {
        switch self {
        case .sensorExpired:
            return .critical
        default:
            return .normal
        }
    }
}

class G7SettingsViewModel: ObservableObject {
    @Published var scanning: Bool = false
    @Published var connected: Bool = false
    @Published var sensorName: String?
    @Published var activatedAt: Date?
    @Published var lastConnect: Date?

    private var cgmManager: G7CGMManager

    var progressBarState: G7ProgressBarState {
        return G7ProgressBarState(lifecycle: cgmManager.lifecycleState)
    }

    init(cgmManager: G7CGMManager) {
        self.cgmManager = cgmManager
        updateValues()

        self.cgmManager.addStateObserver(self, queue: DispatchQueue.main)
    }

    func updateValues() {
        scanning = cgmManager.isScanning
        sensorName = cgmManager.sensorName
        activatedAt = cgmManager.sensorActivatedAt
        connected = cgmManager.isConnected
        lastConnect = cgmManager.lastConnect
    }

    var progressBarColorStyle: ColorStyle {
        switch progressBarState {
        case .warmupProgress:
            return .glucose
        case .searchingForSensor:
            return .dimmed
        case .sensorExpired:
            return .critical
        case .sensorFailed:
            return .dimmed
        case .expirationProgress:
            return .glucose
        }
    }

    var progressBarProgress: Double {
        switch progressBarState {
        case .searchingForSensor:
            return 0
        case .warmupProgress:
            guard let value = progressValue, value > 0 else {
                return 0
            }
            return 1 - value / G7Sensor.warmupDuration
        case .expirationProgress:
            guard let value = progressValue, value > 0 else {
                return 0
            }
            return 1 - value / G7Sensor.lifetime
        case .sensorExpired:
            return 1
        default:
            return 0.5
        }
    }

    var progressValue: TimeInterval? {
        switch progressBarState {
        case .sensorExpired, .sensorFailed, .searchingForSensor:
            return nil
        case .warmupProgress:
            guard let warmupFinishedAt = cgmManager.sensorFinishesWarmupAt else {
                return nil
            }
            return warmupFinishedAt.timeIntervalSinceNow
        case .expirationProgress:
            guard let expiration = cgmManager.sensorExpiresAt else {
                return nil
            }
            return expiration.timeIntervalSinceNow
        }
    }

    func scanForNewSensor() {
        cgmManager.scanForNewSensor()
    }
}

extension G7SettingsViewModel: G7StateObserver {
    func g7StateDidUpdate(_ state: CGMBLEKit.G7CGMManagerState?) {
        updateValues()
    }

    func g7ConnectionStatusDidChange() {
        updateValues()
    }
}
