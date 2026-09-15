//
//  G7DexcomAppWarningView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI

/// Shown before pairing when the Dexcom G7 app is installed.
///
/// A sensor admits one display at a time and the Dexcom app will keep trying
/// to be it, so pairing while it is installed either fails outright or
/// produces a session the two apps fight over. The user has to remove it.
struct G7DexcomAppWarningView: View {
    /// Whether the sensor being paired is one the Dexcom app has been
    /// connected to (an eavesdropping session moving to direct). That is
    /// when the sensor's 15-minute display lease matters, and when readings
    /// stop until pairing completes.
    var isReplacingDexcomAppSession: Bool

    /// Re-checks whether the app is still installed; the screen refuses to
    /// move on while it is.
    var isDexcomAppInstalled: () -> Bool
    var didContinue: () -> Void

    @Environment(\.appName) private var appName
    @Environment(\.guidanceColors) private var guidanceColors

    @State private var stillInstalled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(guidanceColors.warning)
                Text(String(format: LocalizedString("Delete the %@ App", comment: "Title of the Dexcom app warning shown before pairing (1: app name, e.g. Dexcom G7 or Stelo)"), G7DexcomApp.installedAppNames))
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            Text(String(format: LocalizedString("The %@ app is installed on this phone. You must delete it before pairing.", comment: "First paragraph of the Dexcom app warning (1: app name)"), G7DexcomApp.installedAppNames))
                .fixedSize(horizontal: false, vertical: true)

            Text(String(format: LocalizedString("A G7 sensor works with only one app at a time. If the Dexcom app stays installed it will keep connecting to the sensor, and %1$@ will lose readings or fail to pair at all.", comment: "Second paragraph of the Dexcom app warning (1: appName)"), appName))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(.secondary)

            if isReplacingDexcomAppSession {
                VStack(alignment: .leading, spacing: 12) {
                    Text(String(format: LocalizedString("Because the Dexcom app has been using this sensor, wait about 15 minutes after deleting it before pairing; the sensor holds onto its last app for that long. %1$@ will not receive readings until pairing completes.", comment: "Dexcom app warning: lease wait and reading gap when moving an existing session (1: appName)"), appName))
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundColor(.secondary)
                    Text(LocalizedString("You will need this sensor's 4-digit pairing code, printed on its applicator.", comment: "Dexcom app warning: reminder that the code for the current sensor is needed"))
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundColor(.secondary)
                }
            } else {
                Text(LocalizedString("A new sensor that the Dexcom app has never connected to can be paired right away.", comment: "Dexcom app warning: no wait needed for a fresh sensor"))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if stillInstalled {
                Text(String(format: LocalizedString("The %@ app is still installed.", comment: "Message when the user tries to continue with the Dexcom app still present (1: app name)"), G7DexcomApp.installedAppNames))
                    .font(.footnote)
                    .foregroundColor(guidanceColors.critical)
                    .frame(maxWidth: .infinity)
            }

            Button(action: {
                if isDexcomAppInstalled() {
                    stillInstalled = true
                } else {
                    didContinue()
                }
            }) {
                Text(LocalizedString("I've Deleted It", comment: "Button title to confirm the Dexcom app was removed"))
                    .actionButtonStyle(.primary)
            }
        }
        .padding()
        .navigationBarTitle(Text(LocalizedString("Before You Pair", comment: "Navigation title of the Dexcom app warning screen")), displayMode: .inline)
    }
}
