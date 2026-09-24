//
//  G7ScanCodeView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import AVFoundation
import G7SensorKit
import SwiftUI

/// Asks how to give the pairing code, leading with the scan.
///
/// The applicator's barcode carries the sensor's serial as well as the code,
/// and the serial is what lets pairing pass over every other Dexcom sensor in
/// range, so scanning is the way worth offering first. Typing the four digits
/// is one tap away and arrives at the same place.
///
/// Both ways out sit at the bottom, within reach of a thumb. Leading with the
/// scan does not mean putting its button at the top of the screen: that is the
/// far corner of a phone, and it is the action most people will take.
struct G7ScanCodeView: View {
    var didScanCode: (_ code: String, _ serial: String?) -> Void
    var didChooseManualEntry: () -> Void

    @State private var showingScanner = false
    @State private var showingCameraDenied = false
    @State private var showingCameraBusy = false
    /// One scan is all this screen has to give: it hands the code on and the
    /// flow moves to pairing. Without this, two taps in the simulator — where
    /// the stand-in answers immediately, with no sheet in the way — push the
    /// pairing screen twice.
    @State private var hasScanned = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 76))
                        .foregroundColor(.accentColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)

                    Text(LocalizedString("Scan the Applicator", comment: "Title of the screen that offers to scan the applicator barcode"))
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(LocalizedString("The barcode on the sensor applicator holds the 4-digit pairing code and the sensor's serial number.", comment: "First line of the scan screen"))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(LocalizedString("With the serial number, pairing looks for your sensor and passes over every other Dexcom sensor in range.", comment: "Second line of the scan screen, on what the serial number is for"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
            }

            VStack(spacing: 10) {
                Button(action: scanTapped) {
                    Label(LocalizedString("Scan Applicator", comment: "Button title to scan the applicator barcode"), systemImage: "qrcode.viewfinder")
                        .actionButtonStyle(.primary)
                }
                .disabled(hasScanned)

                Button(action: didChooseManualEntry) {
                    Text(LocalizedString("Enter Code by Hand", comment: "Button title to type the pairing code instead of scanning it"))
                        .actionButtonStyle(.secondary)
                }
            }
            .padding([.horizontal, .bottom])
        }
        // Coming back from pairing — "Change Code", or the back button —
        // lands here again, and the screen has to work a second time.
        .onAppear { hasScanned = false }
        .sheet(isPresented: $showingScanner) {
            NavigationView {
                G7PackageScannerView { package in
                    showingScanner = false
                    handleScannedPackage(package)
                }
                .navigationBarTitle(Text(LocalizedString("Scan Applicator", comment: "Navigation title of the applicator scanner")), displayMode: .inline)
                .navigationBarItems(trailing: Button(LocalizedString("Cancel", comment: "Button text to cancel G7 setup")) {
                    showingScanner = false
                })
            }
        }
        .alert(
            LocalizedString("Camera Access Is Off", comment: "Title of the alert shown when camera permission is denied"),
            isPresented: $showingCameraDenied
        ) {
            Button(LocalizedString("Open Settings", comment: "Button title to open the iOS Settings app")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(LocalizedString("Cancel", comment: "Button text to cancel G7 setup"), role: .cancel) {}
        } message: {
            Text(LocalizedString("Allow camera access in Settings to scan the code on the applicator, or type the 4 digits instead.", comment: "Message of the alert shown when camera permission is denied"))
        }
        // No actions: the alert carries a standard OK on its own, and there
        // is nothing for the user to change. Waiting is the whole fix.
        .alert(
            LocalizedString("Camera Is Busy", comment: "Title of the alert shown when the camera cannot start scanning right now"),
            isPresented: $showingCameraBusy
        ) {} message: {
            Text(LocalizedString("Another app is using the camera, or the phone needs a moment. Try again shortly, or enter the 4 digits instead.", comment: "Message of the alert shown when the camera cannot start scanning right now"))
        }
    }

    /// The scanner shows a blank view without camera access, so ask first.
    private func scanTapped() {
        guard !hasScanned else { return }

        #if targetEnvironment(simulator)
        // There is no camera to open, and DataScannerViewController cannot be
        // built where it is unsupported, so the stand-in package stands in for
        // the whole scan.
        if let package = G7PackageScannerView.simulatedPackage {
            handleScannedPackage(package)
            return
        }
        #endif

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            presentScanner()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        presentScanner()
                    } else {
                        showingCameraDenied = true
                    }
                }
            }
        default:
            showingCameraDenied = true
        }
    }

    /// Opens the scanner, unless the camera cannot start it this moment.
    /// Presenting anyway would show a sheet that never finds anything.
    private func presentScanner() {
        if G7PackageScannerView.isAvailable {
            showingScanner = true
        } else {
            showingCameraBusy = true
        }
    }

    /// Only packages carrying a pairing code reach here; the scanner keeps
    /// looking past everything else.
    private func handleScannedPackage(_ package: G7SensorPackage) {
        guard !hasScanned, let pairingCode = package.pairingCode else { return }

        hasScanned = true
        didScanCode(pairingCode, package.serial)
    }
}
