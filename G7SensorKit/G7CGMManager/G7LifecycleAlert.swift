//
//  G7LifecycleAlert.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit

/// The sensor-lifecycle alerts this plugin raises. Glucose alerts are Loop's;
/// these cover the things only the CGM plugin knows: session timing, sensor
/// failure, loss of readings, and a sensor that refuses us.
///
/// The time-based ones are scheduled ahead with a delayed trigger, which
/// Loop turns into a local notification, so they fire whether or not the app
/// is running when the moment comes.
enum G7LifecycleAlert: String, CaseIterable {
    /// 24 hours before the nominal end of session.
    case sensorExpiringSoon
    /// 2 hours before the nominal end of session.
    case sensorExpiringImminently
    /// Nominal end of session; readings continue through the grace period.
    case sensorExpired
    /// End of the grace period; readings stop.
    case sessionEnded
    case sensorFailed
    case signalLoss
    /// The sensor accepted the code but refused the connection, or a stored
    /// key stopped working: something the user has to act on.
    case connectionRefused

    /// How long before nominal expiry each warning fires.
    static let expiringSoonLeadTime = TimeInterval(hours: 24)
    static let expiringImminentlyLeadTime = TimeInterval(hours: 2)

    /// How long without a reading before signal loss is raised. Readings are
    /// 5 minutes apart, so this is three misses plus slack.
    static let signalLossInterval = TimeInterval(minutes: 20)

    /// The alerts whose timing follows the session clock, and so are
    /// (re)scheduled together whenever the sensor or its lifetime changes.
    static let sessionTimed: [G7LifecycleAlert] = [.sensorExpiringSoon, .sensorExpiringImminently, .sensorExpired, .sessionEnded]

    func identifier(managerIdentifier: String) -> Alert.Identifier {
        Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: rawValue)
    }

    /// Reminders you can act on in your own time are `.active`; things that
    /// have stopped, or are about to stop, readings interrupt.
    var interruptionLevel: Alert.InterruptionLevel {
        switch self {
        case .sensorExpiringSoon:
            return .active
        case .sensorExpiringImminently, .sensorExpired, .sessionEnded, .signalLoss, .connectionRefused:
            return .timeSensitive
        case .sensorFailed:
            return .critical
        }
    }

    var title: String {
        switch self {
        case .sensorExpiringSoon:
            return LocalizedString("Sensor Expires in 24 Hours", comment: "Alert title 24 hours before sensor expiry")
        case .sensorExpiringImminently:
            return LocalizedString("Sensor Expires in 2 Hours", comment: "Alert title 2 hours before sensor expiry")
        case .sensorExpired:
            return LocalizedString("Sensor Expired", comment: "Alert title at nominal sensor expiry")
        case .sessionEnded:
            return LocalizedString("Sensor Session Ended", comment: "Alert title at the end of the sensor grace period")
        case .sensorFailed:
            return LocalizedString("Sensor Failed", comment: "Alert title for a failed sensor")
        case .signalLoss:
            return LocalizedString("No Sensor Readings", comment: "Alert title for signal loss")
        case .connectionRefused:
            return LocalizedString("Sensor Connection Refused", comment: "Alert title when the sensor refuses authentication")
        }
    }

    var body: String {
        switch self {
        case .sensorExpiringSoon:
            return LocalizedString("Your sensor session ends in about a day. Have a new sensor ready.", comment: "Alert body 24 hours before sensor expiry")
        case .sensorExpiringImminently:
            return LocalizedString("Your sensor session ends in about 2 hours. Change your sensor soon to avoid a gap in readings.", comment: "Alert body 2 hours before sensor expiry")
        case .sensorExpired:
            return LocalizedString("Your sensor has reached the end of its session. Readings continue for up to 12 more hours; replace it before then.", comment: "Alert body at nominal sensor expiry")
        case .sessionEnded:
            return LocalizedString("Your sensor session has ended and readings have stopped. Apply and pair a new sensor.", comment: "Alert body at the end of the grace period")
        case .sensorFailed:
            return LocalizedString("Your sensor has stopped working and is not sending readings. Remove it and start a new sensor. Check your glucose with a meter in the meantime.", comment: "Alert body for a failed sensor")
        case .signalLoss:
            return LocalizedString("No readings have arrived for 20 minutes. Keep your phone within range of the sensor. If this continues, check your glucose with a meter.", comment: "Alert body for signal loss")
        case .connectionRefused:
            return LocalizedString("The sensor refused to connect. It may be in use by another phone or app. Open the CGM settings for details.", comment: "Alert body when the sensor refuses authentication")
        }
    }

    func alert(managerIdentifier: String, trigger: Alert.Trigger = .immediate) -> Alert {
        let content = Alert.Content(
            title: title,
            body: body,
            acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Alert acknowledgment button label")
        )
        return Alert(
            identifier: identifier(managerIdentifier: managerIdentifier),
            foregroundContent: content,
            backgroundContent: content,
            trigger: trigger,
            interruptionLevel: interruptionLevel
        )
    }
}

/// Pure timing for the session-clock alerts, so it can be tested without a
/// manager: which alerts still lie ahead from `now`, and how far.
enum G7LifecycleAlertSchedule {
    static func delays(
        sensorExpiresAt: Date,
        sensorEndsAt: Date,
        now: Date
    ) -> [G7LifecycleAlert: TimeInterval] {
        let fireDates: [G7LifecycleAlert: Date] = [
            .sensorExpiringSoon: sensorExpiresAt.addingTimeInterval(-G7LifecycleAlert.expiringSoonLeadTime),
            .sensorExpiringImminently: sensorExpiresAt.addingTimeInterval(-G7LifecycleAlert.expiringImminentlyLeadTime),
            .sensorExpired: sensorExpiresAt,
            .sessionEnded: sensorEndsAt
        ]
        var delays: [G7LifecycleAlert: TimeInterval] = [:]
        for (alert, date) in fireDates {
            let delay = date.timeIntervalSince(now)
            // A moment already behind us is not worth an alert on its own;
            // whichever later one still applies will say what matters.
            if delay > 0 {
                delays[alert] = delay
            }
        }
        return delays
    }
}
