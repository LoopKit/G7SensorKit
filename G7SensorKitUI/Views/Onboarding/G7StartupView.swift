//
//  G7StartupView.swift
//  CGMBLEKitUI
//
//  Created by Pete Schwamb on 9/24/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import SwiftUI

/// First screen of setup. Two ways in: pair directly (the normal path), or
/// keep relying on the Dexcom app, which exists for someone mid-session on a
/// sensor whose pairing code they no longer have.
struct G7StartupView: View {
    var didChoosePairing: (() -> Void)?
    var didChooseDexcomApp: (() -> Void)?
    var didCancel: (() -> Void)?

    @Environment(\.appName) private var appName

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(LocalizedString("Dexcom G7", comment: "Title on WelcomeView"))
                .font(.largeTitle)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
            VStack(alignment: .center) {
                Image(frameworkImage: "g7")
                    .resizable()
                    .aspectRatio(contentMode: ContentMode.fit)
                    .frame(height: 120)
                    .padding(.horizontal)
            }.frame(maxWidth: .infinity)

            Text(String(format: LocalizedString("%1$@ connects to your G7, ONE+ or Stelo sensor directly. Pair it with the 4-digit code printed on the sensor applicator, and the Dexcom app is not needed.", comment: "Descriptive text on G7StartupView (1: appName)"), self.appName))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(.secondary)

            Spacer()

            Button(action: { self.didChoosePairing?() }) {
                Text(LocalizedString("Pair Sensor", comment: "Button title to start direct pairing"))
                    .actionButtonStyle(.primary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedString("Already wearing a sensor and don't have its code?", comment: "Heading above the legacy Dexcom-app setup option"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Button(action: { self.didChooseDexcomApp?() }) {
                    Text(LocalizedString("Use with the Dexcom App Instead", comment: "Button title to set up in eavesdropping mode alongside the Dexcom app"))
                        .actionButtonStyle(.secondary)
                }
                Text(String(format: LocalizedString("%1$@ will read glucose from the Dexcom app's session until you pair a sensor. The Dexcom app must stay installed for this to work.", comment: "Explanation of eavesdropping mode on G7StartupView (1: appName)"), self.appName))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: { self.didCancel?() } ) {
                Text(LocalizedString("Cancel", comment: "Button text to cancel G7 setup"))
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
        .padding()
        .environment(\.horizontalSizeClass, .compact)
        .navigationBarTitle("")
        .navigationBarHidden(true)
    }
}

struct WelcomeView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            G7StartupView()
        }
    }
}
