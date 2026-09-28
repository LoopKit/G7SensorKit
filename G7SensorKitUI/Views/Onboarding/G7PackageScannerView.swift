//
//  G7PackageScannerView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  Derived from DexKit by Erik Tolboom (https://github.com/nightscout/DexKit).
//

import G7SensorKit
import SwiftUI
import VisionKit

/// Reads the GS1 Data Matrix on a sensor applicator with the camera.
struct G7PackageScannerView: UIViewControllerRepresentable {
    var didScan: (G7SensorPackage) -> Void

    /// Whether scanning can be offered at all: a device with the hardware,
    /// and a host app that declares camera usage. Asking for camera access
    /// without `NSCameraUsageDescription` terminates the app.
    ///
    /// Both conditions hold for as long as the app runs, which is what makes
    /// this the one to decide a screen on.
    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        // No camera in the simulator, so the scan path could not be walked at
        // all: not the screen that leads with it, and not the serial filter
        // it feeds. Offer it and answer with a stand-in package, the way the
        // pairing run answers with a stand-in sensor.
        return true
        #else
        return DataScannerViewController.isSupported
            && Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
        #endif
    }

    /// Whether the scanner can start *right now*. Apple turns this off while
    /// the camera is busy elsewhere or the device is too hot, and back on by
    /// itself, so it is only worth asking at the moment of scanning — never
    /// to decide which screen someone sees.
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return isSupported && DataScannerViewController.isAvailable
        #endif
    }

    #if targetEnvironment(simulator)
    /// A stand-in for a real applicator: a Dexcom GTIN, a serial and a code,
    /// parsed from a synthetic Data Matrix payload so the real parser is
    /// still the thing under the screen.
    static var simulatedPackage: G7SensorPackage? {
        let groupSeparator = "\u{1D}"
        return G7SensorPackage(
            dataMatrix: "0100386270001863" + "17260531" + "10LOT42"
                + groupSeparator + "217810293746"
                + groupSeparator + "2404321"
        )
    }
    #endif

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.dataMatrix])],
            qualityLevel: .accurate,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(didScan: didScan)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let didScan: (G7SensorPackage) -> Void
        private var handled = false

        init(didScan: @escaping (G7SensorPackage) -> Void) {
            self.didScan = didScan
        }

        /// The camera sees whatever is in front of it, so anything that is not
        /// an applicator carrying a pairing code is passed over in silence and
        /// scanning continues. Stopping to report each barcode that wandered
        /// through the frame would be noise; the way out is Cancel and typing
        /// the code.
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !handled else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue,
                      let package = G7SensorPackage(dataMatrix: payload),
                      package.pairingCode != nil
                else {
                    continue
                }
                handled = true
                scanner.stopScanning()
                didScan(package)
                return
            }
        }
    }
}
