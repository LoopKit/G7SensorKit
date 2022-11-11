//
//  G7CGMManager+UI.swift
//  CGMBLEKitUI
//
//  Created by Pete Schwamb on 9/24/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import G7SensorKit
import LoopKitUI
import LoopKit

public struct G7DeviceStatusHighlight: DeviceStatusHighlight, Equatable {
    public let localizedMessage: String
    public let imageName: String
    public let state: DeviceStatusHighlightState
    init(localizedMessage: String, imageName: String, state: DeviceStatusHighlightState) {
        self.localizedMessage = localizedMessage
        self.imageName = imageName
        self.state = state
    }
}

extension G7CGMManager: CGMManagerUI {
    public static var onboardingImage: UIImage? {
        return nil
    }

    public static func setupViewController(bluetoothProvider: BluetoothProvider, displayGlucoseUnitObservable: DisplayGlucoseUnitObservable, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {

        let vc = G7UICoordinator(colorPalette: colorPalette, allowDebugFeatures: allowDebugFeatures)
        return .userInteractionRequired(vc)
    }

    public func settingsViewController(bluetoothProvider: BluetoothProvider, displayGlucoseUnitObservable: DisplayGlucoseUnitObservable, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) ->CGMManagerViewController {

        return G7UICoordinator(cgmManager: self, colorPalette: colorPalette, allowDebugFeatures: allowDebugFeatures)
    }

    public var smallImage: UIImage? {
        UIImage(named: "g7", in: Bundle(for: Self.self), compatibleWith: nil)!
    }

    // TODO Placeholder.
    public var cgmStatusHighlight: DeviceStatusHighlight? {

        if lifecycleState == .searching {
            return G7DeviceStatusHighlight(
                localizedMessage: LocalizedString("Searching for\nSensor", comment: "G7 Status highlight text for searching for sensor"),
                imageName: "dot.radiowaves.left.and.right",
                state: .normalCGM)
        }

        if lifecycleState == .expired {
            return G7DeviceStatusHighlight(
                localizedMessage: LocalizedString("Sensor\nExpired", comment: "G7 Status highlight text for sensor expired"),
                imageName: "clock",
                state: .normalCGM)
        }

        if let latestReadingReceivedAt = state.latestReadingReceivedAt, latestReadingReceivedAt.timeIntervalSinceNow < -.minutes(15) {
            return G7DeviceStatusHighlight(
                localizedMessage: LocalizedString("Signal\nLoss", comment: "G7 Status highlight text for signal loss"),
                imageName: "exclamationmark.circle.fill",
                state: .warning)
        }

        switch lifecycleState {
        case .warmup:
            return G7DeviceStatusHighlight(
                localizedMessage: LocalizedString("Sensor\nWarmup", comment: "G7 Status highlight text for sensor warmup"),
                imageName: "clock",
                state: .normalCGM)
        case .error:
            return G7DeviceStatusHighlight(
                localizedMessage: LocalizedString("Sensor\nError", comment: "G7 Status highlight text for sensor error"),
                imageName: "exclamationmark.circle.fill",
                state: .warning)
        default:
            return nil
        }

    }

    // TODO Placeholder.
    public var cgmStatusBadge: DeviceStatusBadge? {
        return nil
    }

    // TODO Placeholder.
    public var cgmLifecycleProgress: DeviceLifecycleProgress? {
        return nil
    }
}
