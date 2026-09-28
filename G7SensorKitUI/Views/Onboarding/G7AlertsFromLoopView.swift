//
//  G7AlertsFromLoopView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI

/// Shown while an eavesdropping session moves to direct: with the Dexcom app
/// gone, every alert the user is used to now has to come from Loop.
struct G7AlertsFromLoopView: View {
    var didContinue: () -> Void

    @Environment(\.appName) private var appName

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "bell.badge.fill")
                        .font(.largeTitle)
                        .foregroundColor(.accentColor)
                    Text(String(format: LocalizedString("Alerts Now Come From %@", comment: "Title of the alerts hand-off page shown when moving to a direct connection (1: appName)"), appName))
                        .font(.title2)
                        .fontWeight(.semibold)
                }

                Text(String(format: LocalizedString("Until now the Dexcom app has been alerting you. Once %1$@ connects to the sensor directly, the Dexcom app is out of the picture, and so are its alerts.", comment: "First paragraph of the alerts hand-off page (1: appName)"), appName))
                    .fixedSize(horizontal: false, vertical: true)

                section(
                    title: LocalizedString("Glucose Alerts", comment: "Heading for the glucose alerts part of the alerts hand-off page"),
                    icon: "waveform.path.ecg",
                    body: String(format: LocalizedString("High, low and urgent low glucose alerts are issued by %1$@ according to its own alert settings. Review them so they match what you had in the Dexcom app.", comment: "Glucose alerts paragraph of the alerts hand-off page (1: appName)"), appName)
                )

                section(
                    title: LocalizedString("Sensor Alerts", comment: "Heading for the sensor alerts part of the alerts hand-off page"),
                    icon: "sensor.fill",
                    body: String(format: LocalizedString("The G7 integration raises these itself and delivers them as %1$@ notifications:", comment: "Sensor alerts paragraph of the alerts hand-off page (1: appName)"), appName),
                    bullets: [
                        LocalizedString("Sensor expiring, 24 hours and again 2 hours before", comment: "Sensor alert list item: expiring"),
                        LocalizedString("Sensor expired and session ended", comment: "Sensor alert list item: expired"),
                        LocalizedString("Sensor failed", comment: "Sensor alert list item: failed"),
                        LocalizedString("Signal loss, after 20 minutes without a reading", comment: "Sensor alert list item: signal loss"),
                    ]
                )

                Text(LocalizedString("Anything else you had set up in the Dexcom app, such as rising or falling rate alerts, is not carried over.", comment: "Closing note of the alerts hand-off page"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: didContinue) {
                Text(LocalizedString("Continue", comment: "Button title to continue"))
                    .actionButtonStyle(.primary)
            }
            .padding()
            .background(Color(.systemBackground))
        }
    }

    private func section(title: String, icon: String, body: String, bullets: [String] = []) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(bullets, id: \.self) { bullet in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                    Text(bullet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(.secondary)
                .padding(.leading, 4)
            }
        }
    }
}
