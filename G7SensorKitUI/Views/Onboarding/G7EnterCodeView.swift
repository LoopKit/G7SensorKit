//
//  G7EnterCodeView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import AVFoundation
import G7SensorKit
import SwiftUI

/// Collects the 4-digit pairing code, by typing or by scanning the
/// applicator's Data Matrix.
struct G7EnterCodeView: View {
    var didEnterCode: (_ code: String, _ serial: String?) -> Void

    @State private var code = ""
    /// The code and serial from a scanned applicator. The serial only rides
    /// along while the code still matches what was scanned: it belongs to that
    /// applicator,
    /// not to whatever gets typed afterwards.
    @State private var scannedCode: String?
    @State private var scannedSerial: String?
    @State private var showingScanner = false
    @State private var showingCameraDenied = false
    @State private var scanMessage: String?

    @FocusState private var codeFieldFocused: Bool

    private var isValid: Bool {
        G7PairingService.isValidPairingCode(code)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(LocalizedString("Enter the 4-digit pairing code printed on the sensor applicator, or scan the applicator's barcode.", comment: "Instructions on the pairing code entry screen"))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(.secondary)

            Text(LocalizedString("There is nothing to do in the Dexcom app first; the sensor is ready to pair as soon as it is on.", comment: "Reminder on the code entry screen that the Dexcom app is not involved"))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(.secondary)

            TextField(LocalizedString("Pairing Code", comment: "Placeholder for the pairing code field"), text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
                .focused($codeFieldFocused)
                .onChange(of: code) { _, newValue in
                    let digits = newValue.filter(\.isNumber)
                    let trimmed = String(digits.prefix(4))
                    if trimmed != newValue {
                        code = trimmed
                    }
                    if trimmed != scannedCode {
                        scannedSerial = nil
                    }
                }

            if G7PackageScannerView.isAvailable {
                Button(action: scanTapped) {
                    Label(LocalizedString("Scan Applicator", comment: "Button title to scan the applicator barcode"), systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if let scanMessage = scanMessage {
                Text(scanMessage)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { didEnterCode(code, scannedSerial) }) {
                Text(LocalizedString("Continue", comment: "Button title for starting setup"))
                    .actionButtonStyle(.primary)
            }
            .disabled(!isValid)
        }
        .padding()
        .onAppear { codeFieldFocused = true }
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
        .navigationBarTitle(Text(LocalizedString("Pairing Code", comment: "Navigation title of the pairing code entry screen")), displayMode: .inline)
    }

    /// The scanner shows a blank view without camera access, so ask first.
    private func scanTapped() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            showingScanner = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        showingScanner = true
                    } else {
                        showingCameraDenied = true
                    }
                }
            }
        default:
            showingCameraDenied = true
        }
    }

    private func handleScannedPackage(_ package: G7SensorPackage) {
        guard let pairingCode = package.pairingCode else {
            scanMessage = package.isDexcom
                ? LocalizedString("That barcode has no pairing code. Enter the code from the applicator instead.", comment: "Message after scanning a Dexcom barcode without a pairing code")
                : LocalizedString("That doesn't look like a Dexcom applicator.", comment: "Message after scanning a non-Dexcom barcode")
            return
        }
        scannedCode = pairingCode
        scannedSerial = package.serial
        code = pairingCode
        scanMessage = package.serial.map { serial in
            String(format: LocalizedString("Scanned sensor %@", comment: "Message after a successful package scan (1: serial number)"), serial)
        }
    }
}
