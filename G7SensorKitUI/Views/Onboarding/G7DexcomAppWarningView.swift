//
//  G7DexcomAppWarningView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI

/// Shown before pairing when a Dexcom app is installed.
///
/// A sensor admits one display at a time and the Dexcom app will keep trying
/// to be it, so the app has to go before pairing, and this screen will not
/// move on until it has. The check is made when the button is pressed rather
/// than by disabling it: a disabled button with no explanation is a dead end,
/// while a press that refuses can say why.
///
/// Both ways out remove the binary, which is the point. Force quitting and
/// revoking Bluetooth were offered here once and are not any more: each
/// leaves the app installed and one tap from taking the sensor back, so a
/// session paired that way can be lost weeks later with nothing on screen to
/// explain it. Offloading is kept because it is deletion that spares the
/// history, not because it is a softer option.
///
/// Three things the copy has to keep doing: say what to do before why, give
/// each way out its own block so none of it reads as a paragraph to wade
/// through, and stay in primary text. Grey on white is the first thing to
/// go unread, and this screen is the one that decides whether pairing works
/// at all.
struct G7DexcomAppWarningView: View {
    /// Whether the sensor being paired is one the Dexcom app has been
    /// connected to (an eavesdropping session moving to direct). That is
    /// when the sensor's 15-minute display lease matters, and when readings
    /// stop until pairing completes.
    var isReplacingDexcomAppSession: Bool

    /// Re-checks whether the app is still installed. The screen refuses to
    /// move on while it is, and the answer is taken again at the moment of
    /// the press, not read off state that may have gone stale.
    var isDexcomAppInstalled: () -> Bool
    var didContinue: () -> Void

    @Environment(\.appName) private var appName
    @Environment(\.guidanceColors) private var guidanceColors
    @Environment(\.scenePhase) private var scenePhase

    @State private var isInstalled = true
    /// Set when the button was pressed with the app still there, to say so.
    @State private var wasStillInstalledOnPress = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundColor(guidanceColors.warning)
                        Text(String(format: LocalizedString("Remove the %@ App", comment: "Title of the Dexcom app warning shown before pairing (1: app name, e.g. Dexcom G7 or Stelo)"), G7DexcomApp.installedAppNames))
                            .font(.title2)
                            .fontWeight(.semibold)
                    }

                    Text(String(format: LocalizedString("A sensor works with only one app at a time. The %1$@ app has to come off this phone before %2$@ can pair with the sensor, and has to stay off.", comment: "First paragraph of the Dexcom app warning (1: Dexcom app name, 2: appName)"), G7DexcomApp.installedAppNames, appName))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(LocalizedString("Do one of these:", comment: "Lead-in to the list of ways to remove the Dexcom app"))
                        .font(.headline)
                        .padding(.top, 2)

                    option(
                        number: 1,
                        symbol: "trash",
                        title: LocalizedString("Delete the app", comment: "Title of the option to delete the Dexcom app"),
                        detail: LocalizedString("Touch and hold its icon, then Remove App. Your readings stay in the Dexcom cloud.", comment: "Detail of the option to delete the Dexcom app")
                    )
                    orSeparator
                    option(
                        number: 2,
                        symbol: "arrow.down.app",
                        title: LocalizedString("Offload the app", comment: "Title of the option to offload the Dexcom app"),
                        detail: LocalizedString("In Settings › General › iPhone Storage. Removes the app but keeps its data, so reinstalling restores it.", comment: "Detail of the option to offload the Dexcom app")
                    )

                    tail
                        .padding(.top, 2)
                }
                .padding()
            }

            VStack(spacing: 10) {
                if wasStillInstalledOnPress {
                    Text(String(format: LocalizedString("The %@ app is still on this phone. Remove it, then come back here.", comment: "Message when the user tries to continue with the Dexcom app still present (1: app name)"), G7DexcomApp.installedAppNames))
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundColor(guidanceColors.critical)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(action: {
                    // Asked again here, not taken from `isInstalled`: that is
                    // refreshed on a foreground, and this is the moment the
                    // answer actually decides something.
                    if isDexcomAppInstalled() {
                        isInstalled = true
                        wasStillInstalledOnPress = true
                    } else {
                        didContinue()
                    }
                }) {
                    Text(LocalizedString("I've Removed It", comment: "Button title to confirm the Dexcom app was deleted or offloaded"))
                        .actionButtonStyle(.primary)
                }
            }
            .padding([.horizontal, .bottom])
        }
        .onAppear { isInstalled = isDexcomAppInstalled() }
        // Coming back from deleting the app is a return to the foreground,
        // not a fresh appearance: the screen never left the hierarchy, so
        // `onAppear` does not fire again and the check has to be redone here
        // or it reports what was true before the user went to do the thing
        // this screen asked for.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                isInstalled = isDexcomAppInstalled()
                if !isInstalled {
                    wasStillInstalledOnPress = false
                }
            }
        }
    }

    /// What is left to know once the user has picked a way: how long the
    /// sensor stays loyal to the app that had it, and what to have ready.
    ///
    /// Only an eavesdropping session tells us the Dexcom app has had this
    /// sensor. Everywhere else the sensor may be fresh out of the box or may
    /// have been on the user's arm for days with the Dexcom app reading it,
    /// and we cannot tell which, so the wait is stated as the condition it
    /// is rather than asserted either way.
    private var tail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isReplacingDexcomAppSession {
                Text(LocalizedString("This sensor has been used by the Dexcom app. Wait about 15 minutes after it last connected, then pair.", comment: "Dexcom app warning: lease wait when moving an existing session"))
                    .fixedSize(horizontal: false, vertical: true)
                Text(LocalizedString("You need the 4-digit code from this sensor's applicator.", comment: "Dexcom app warning: reminder that the code for the current sensor is needed"))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(LocalizedString("If the Dexcom app has used the sensor you are pairing, wait about 15 minutes after it last connected. A sensor it has never used can be paired right away.", comment: "Dexcom app warning: the lease wait applies only if the Dexcom app has used this sensor"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Deleting the app does not hand the sensor back: the lease it
            // holds runs on the sensor's own clock, so the wait above still
            // stands and this only confirms the app is gone.
            if !isInstalled {
                Label(
                    String(format: LocalizedString("The %@ app is gone.", comment: "Message once the Dexcom app has been removed (1: app name)"), G7DexcomApp.installedAppNames),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundColor(.green)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var orSeparator: some View {
        Text(LocalizedString("OR", comment: "Separator between the ways to stop the Dexcom app"))
            .font(.footnote.weight(.semibold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
    }

    private func option(number: Int, symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundColor(.accentColor)
                Text(String(format: LocalizedString("OPTION %d", comment: "Label numbering a way to stop the Dexcom app (1: number)"), number))
                    .font(.caption.weight(.bold))
                    .foregroundColor(.accentColor)
            }

            Text(title)
                .font(.headline)

            Text(detail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}
