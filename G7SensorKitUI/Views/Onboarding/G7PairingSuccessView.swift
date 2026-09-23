//
//  G7PairingSuccessView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import G7SensorKit
import SwiftUI

struct G7PairingSuccessView: View {
    /// The model that paired, so the sensor on this screen is the one the
    /// search just settled on rather than a stand-in.
    var model: G7SensorModel
    var deviceName: String?
    /// Whether setup continues after this page (Dexcom Share sign-in).
    var hasNextStep = false
    var didFinish: () -> Void

    @Environment(\.appName) private var appName

    var body: some View {
        // Laid out like the pairing screen this arrives from: the sensor
        // centred at the top, the text from one left edge under it, and the
        // way on pinned below. Centring the content instead would move the
        // sensor as the screen replaced the one before it.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    G7SensorHero(model: model, outcome: .succeeded)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(LocalizedString("Sensor Paired", comment: "Title of the pairing success screen"))
                            .font(.title2)
                            .fontWeight(.semibold)

                        if let deviceName = deviceName {
                            Text(deviceName)
                                .foregroundColor(.secondary)
                        }
                    }

                    Text(String(format: LocalizedString("%1$@ is now connected to the sensor directly. Readings arrive every 5 minutes; a new sensor needs about 30 minutes to warm up first.", comment: "Body of the pairing success screen (1: appName)"), appName))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(LocalizedString("Do not let a Dexcom app use this sensor from now on. A sensor works with only one app at a time.", comment: "Reminder on the pairing success screen"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
            }

            Button(action: didFinish) {
                Text(hasNextStep
                    ? LocalizedString("Continue", comment: "Button title to continue")
                    : LocalizedString("Done", comment: "Button title to finish setup"))
                    .actionButtonStyle(.primary)
            }
            .padding([.horizontal, .bottom])
        }
        .navigationBarBackButtonHidden(true)
    }
}
