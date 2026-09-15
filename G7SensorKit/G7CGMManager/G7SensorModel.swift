//
//  G7SensorModel.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// The G7-family sensors, which share the protocol and differ in what they
/// call themselves over the air. A sensor advertises as `<prefix>xx` and
/// reports "Dexcomxx" once connected, so the model is only knowable from the
/// advertised name, which is what a session keeps as its sensor ID.
public enum G7SensorModel: String, CaseIterable {
    case g7
    case onePlus
    case stelo

    /// The first four characters of the advertised name.
    public var advertisedPrefix: String {
        switch self {
        case .g7: return "DXCM"
        case .onePlus: return "DX02"
        case .stelo: return "DX01"
        }
    }

    public var displayName: String {
        switch self {
        case .g7: return "G7"
        case .onePlus: return "ONE+"
        case .stelo: return "Stelo"
        }
    }

    /// The full product name, with the nominal session length once the
    /// sensor has reported one: "Dexcom G7", then "Dexcom G7 15 Day". The
    /// length the sensor reports includes the 12-hour grace period; the
    /// nominal figure is what is printed on the box.
    public func displayName(sessionLength: TimeInterval?) -> String {
        guard let sessionLength = sessionLength else {
            return localizedTitle
        }
        let nominalDays = Int(((sessionLength - G7Sensor.gracePeriod) / TimeInterval(hours: 24)).rounded())
        return String(format: LocalizedString("%1$@ %2$d Day", comment: "Sensor product name with its nominal session length (1: name, e.g. Dexcom G7, 2: days)"), localizedTitle, nominalDays)
    }

    public var localizedTitle: String {
        switch self {
        case .g7: return LocalizedString("Dexcom G7", comment: "CGM display title")
        case .onePlus: return LocalizedString("Dexcom ONE+", comment: "CGM display title for a ONE+ sensor")
        case .stelo: return LocalizedString("Dexcom Stelo", comment: "CGM display title for a Stelo sensor")
        }
    }

    /// The model a name belongs to, or nil for a name outside the family.
    public init?(advertisedName name: String) {
        guard let model = G7SensorModel.allCases.first(where: { name.hasPrefix($0.advertisedPrefix) }) else {
            return nil
        }
        self = model
    }

    /// Whether `name` is one of ours, in either of its forms.
    static func isFamilyName(_ name: String) -> Bool {
        G7SensorModel(advertisedName: name) != nil || name.hasPrefix("Dexcom")
    }
}
