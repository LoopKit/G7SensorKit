//
//  G7SessionMode.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// How this app gets readings out of a G7-family sensor.
public enum G7SessionMode: String, Equatable, CaseIterable {

    /// Watch a session the Dexcom app owns.
    ///
    /// We connect to the sensor but never authenticate; we wait until the
    /// Dexcom app's own handshake completes on the link, then subscribe to
    /// the readings it is already causing the sensor to broadcast. That makes
    /// the Dexcom app a hard requirement: it must stay installed, and it must
    /// keep the sensor's session alive.
    ///
    /// This is how the plugin worked before direct pairing existed, and it
    /// remains for people who are mid-session on a sensor whose pairing code
    /// they no longer have. New sessions should pair instead.
    case eavesdropping

    /// Hold the sensor's display slot ourselves.
    ///
    /// A pairing code and an EC-JPAKE handshake make this app the display the
    /// sensor talks to, so no Dexcom app is involved at all. Because a sensor
    /// admits only one display, the Dexcom app must not also be using it.
    case direct

    /// Whether the Dexcom app is required for this mode to produce readings.
    public var requiresDexcomApp: Bool {
        self == .eavesdropping
    }
}
