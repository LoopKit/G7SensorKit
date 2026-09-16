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

    /// Whether scanning can be offered at all. Requires a device with a
    /// camera and a host app that declares camera usage: asking for camera
    /// access without `NSCameraUsageDescription` terminates the app.
    static var isAvailable: Bool {
        DataScannerViewController.isSupported
            && DataScannerViewController.isAvailable
            && Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
    }

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

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !handled else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue,
                      let package = G7SensorPackage(dataMatrix: payload)
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
