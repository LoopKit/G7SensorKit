//
//  G7PairingViewModel.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import G7SensorKit

/// Drives one pairing attempt for the pairing screen.
final class G7PairingViewModel: ObservableObject {

    @Published private(set) var state: G7PairingState = .idle

    /// Assumed fine until the radio says otherwise, so the screen does not
    /// flash a warning before the central has reported in.
    @Published private(set) var bluetoothState: CBManagerState = .poweredOn

    let pairingCode: String
    let serial: String?
    private let excludedPeripheral: UUID?

    private let service: G7PairingService
    private let onSuccess: (_ peripheralIdentifier: UUID, _ sharedKey: Data, _ deviceName: String?, _ handoff: G7PairingHandoff?) -> Void
    private let onLog: ((String) -> Void)?

    /// - Parameter cgmManager: the manager being re-paired, if any. Its
    ///   session's Bluetooth central is borrowed for the run.
    init(
        pairingCode: String,
        serial: String?,
        cgmManager: G7CGMManager?,
        onLog: ((String) -> Void)? = nil,
        onSuccess: @escaping (_ peripheralIdentifier: UUID, _ sharedKey: Data, _ deviceName: String?, _ handoff: G7PairingHandoff?) -> Void
    ) {
        self.pairingCode = pairingCode
        // The sensor a session already holds is not the one being replaced;
        // trying it with the new code just earns a rejection. The same code
        // entered again means the same sensor, though: re-pairing it, so it
        // is the one to look for, by serial when the session has learned it.
        let isCurrentSensor = cgmManager?.state.pairingCode == pairingCode
        self.serial = serial ?? (isCurrentSensor ? cgmManager?.state.transmitterVersion?.serialNumberString : nil)
        self.excludedPeripheral = isCurrentSensor ? nil : cgmManager?.state.peripheralIdentifier
        self.onLog = onLog
        self.onSuccess = onSuccess
        service = G7PairingService(cgmManager: cgmManager)

        service.onLog = onLog
        service.onBluetoothStateChange = { [weak self] state in
            self?.bluetoothState = state
        }
        service.onStateChange = { [weak self] state in
            guard let self = self else { return }
            self.state = state
            if case .succeeded(let peripheralIdentifier, let sharedKey, let deviceName) = state {
                self.onSuccess(peripheralIdentifier, sharedKey, deviceName, self.service.handOff())
            }
        }
    }

    func start() {
        service.start(pairingCode: pairingCode, serial: serial, excludingPeripheral: excludedPeripheral)
    }

    func retry() {
        start()
    }

    func cancel() {
        service.cancel()
    }

    var scanStartedAt: Date? {
        service.scanStartedAt
    }

    /// Why pairing cannot make progress right now, if the radio is the reason.
    var bluetoothProblem: String? {
        guard isWorking else { return nil }
        switch bluetoothState {
        case .poweredOff:
            return LocalizedString("Bluetooth is off. Turn it on in Settings or Control Center to pair.", comment: "Pairing screen notice when Bluetooth is powered off")
        case .unauthorized:
            return LocalizedString("Bluetooth access is not allowed. Turn it on for this app in Settings › Privacy & Security › Bluetooth.", comment: "Pairing screen notice when the app lacks Bluetooth permission")
        default:
            return nil
        }
    }

    var isWorking: Bool {
        switch state {
        case .scanning, .authenticating:
            return true
        case .idle, .succeeded, .failed:
            return false
        }
    }

    var statusTitle: String {
        switch state {
        case .idle:
            return LocalizedString("Preparing…", comment: "Pairing status before the scan starts")
        case .scanning(let candidates) where candidates.isEmpty:
            return LocalizedString("Searching for sensor…", comment: "Pairing status while scanning with no sensor found yet")
        case .scanning:
            return LocalizedString("Connecting…", comment: "Pairing status once a sensor has been found")
        case .authenticating:
            return LocalizedString("Pairing…", comment: "Pairing status during the handshake")
        case .succeeded:
            return LocalizedString("Paired", comment: "Pairing status on success")
        case .failed:
            return LocalizedString("Pairing Failed", comment: "Pairing status on failure")
        }
    }

    var statusDetail: String? {
        switch state {
        case .idle:
            return nil
        case .scanning(let candidates) where candidates.isEmpty:
            return LocalizedString(
                "Keep your phone near the sensor. A sensor that was recently used by the Dexcom app or another phone can take up to 15 minutes to become available; this screen will keep looking.",
                comment: "Pairing guidance while scanning"
            )
        case .scanning(let candidates):
            return String(
                format: LocalizedString("Found %@", comment: "Pairing detail listing discovered sensors (1: comma-separated names)"),
                candidates.joined(separator: ", ")
            )
        case .authenticating(let candidate, let attempt):
            if attempt > 1 {
                return String(
                    format: LocalizedString("%1$@, attempt %2$d", comment: "Pairing detail for a retry (1: sensor name, 2: attempt number)"),
                    candidate,
                    attempt
                )
            }
            return candidate
        case .succeeded(_, _, let deviceName):
            return deviceName
        case .failed(let reason):
            return reason
        }
    }
}
