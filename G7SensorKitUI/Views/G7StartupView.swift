//
//  G7StartupView.swift
//  CGMBLEKitUI
//
//  Created by Pete Schwamb on 9/24/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import SwiftUI

struct G7StartupView: View {
    var didContinue: (() -> Void)?
    var didCancel: (() -> Void)?

    @Environment(\.appName) private var appName

    var body: some View {
        VStack(alignment: .center, spacing: 20) {
            Spacer()
            Text(LocalizedString("Dexcom G7", comment: "Title on WelcomeView"))
                .font(.largeTitle)
                .fontWeight(.semibold)
            VStack(alignment: .center) {
                Image(frameworkImage: "g7")
                    .resizable()
                    .aspectRatio(contentMode: ContentMode.fit)
                    .frame(height: 120)
                    .padding(.horizontal)
            }.frame(maxWidth: .infinity)
            Text(String(format: LocalizedString("%1$@ can read CGM data from the G7 platform, but you must still use the Dexcom App for pairing, calibration, alarms and other sensor management available to the sensor series (G7, ONE+, Stelo).\n\nWARNING: Dexcom Stelo app provides no alerts and alarms. Glucose alerts and alarms are not provided by %2$@.", comment: "Descriptive text on G7StartupView  (1: appName, 2: appName)"), self.appName, self.appName))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(.secondary)
            Spacer()
            Button(action: { self.didContinue?() }) {
                Text(LocalizedString("Continue", comment:"Button title for starting setup"))
                    .actionButtonStyle(.primary)
            }
            Button(action: { self.didCancel?() } ) {
                Text(LocalizedString("Cancel", comment: "Button text to cancel G7 setup")).padding(.top, 20)
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
        .previewDevice("iPod touch (7th generation)")
    }
}
