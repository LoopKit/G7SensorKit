//
//  G7PairingSuccessView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI

struct G7PairingSuccessView: View {
    var deviceName: String?
    /// Whether setup continues after this page (Dexcom Share sign-in).
    var hasNextStep = false
    var didFinish: () -> Void

    @Environment(\.appName) private var appName
    @Environment(\.guidanceColors) private var guidanceColors

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(guidanceColors.acceptable)

            Text(LocalizedString("Sensor Paired", comment: "Title of the pairing success screen"))
                .font(.title2)
                .fontWeight(.semibold)

            if let deviceName = deviceName {
                Text(deviceName)
                    .foregroundColor(.secondary)
            }

            Text(String(format: LocalizedString("%1$@ is now connected to the sensor directly. Readings arrive every 5 minutes; a new sensor needs about 30 minutes to warm up first.", comment: "Body of the pairing success screen (1: appName)"), appName))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(LocalizedString("Do not install or use the Dexcom G7 app with this sensor.", comment: "Reminder on the pairing success screen"))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Spacer()

            Button(action: didFinish) {
                Text(hasNextStep
                    ? LocalizedString("Continue", comment: "Button title to continue")
                    : LocalizedString("Done", comment: "Button title to finish setup"))
                    .actionButtonStyle(.primary)
            }
        }
        .padding()
        .navigationBarBackButtonHidden(true)
        .navigationBarTitle("", displayMode: .inline)
    }
}
