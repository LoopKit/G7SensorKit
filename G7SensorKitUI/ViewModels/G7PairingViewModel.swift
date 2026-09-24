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

    /// Which product to picture: the sensor under trial, or the most recent
    /// one heard from before that. G7 until one of them says otherwise, since
    /// the screen has to show something while the scan is still empty.
    var displayModel: G7SensorModel {
        switch state {
        case .authenticating(let candidate, _):
            return G7SensorModel(advertisedName: candidate) ?? .g7
        case .scanning(let candidates):
            return candidates.last.flatMap(G7SensorModel.init(advertisedName:)) ?? .g7
        case .succeeded(_, _, let deviceName):
            return deviceName.flatMap(G7SensorModel.init(advertisedName:)) ?? .g7
        case .idle, .failed:
            return .g7
        }
    }

    /// The serial the scan is narrowed to: the one from the scanned
    /// applicator (or the one the session already knows, when re-pairing its
    /// own sensor), and only when it can actually narrow anything.
    var filteredSerial: String? {
        guard let serial = serial, G7PairingService.canFilterBySerial(serial) else {
            return nil
        }
        return serial
    }

    /// Says so on screen when the run is only looking for one sensor. A user
    /// watching it pass over a sensor sitting right next to the phone should
    /// be able to see why.
    var serialFilterNote: String? {
        guard let serial = filteredSerial, isWorking else {
            return nil
        }
        return String(
            format: LocalizedString(
                "Waiting for the sensor with serial %@, from the applicator you scanned. Sensors in range that cannot have that serial are skipped.",
                comment: "Pairing note shown while the scan is narrowed to a scanned sensor's serial (1: serial number)"
            ),
            serial
        )
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
        if bluetoothProblem != nil {
            return LocalizedString("Bluetooth Unavailable", comment: "Pairing status while the radio is off or not permitted")
        }
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
        case .scanning, .authenticating:
            // Deliberately about the run, not about a candidate. Which sensor
            // is under trial, and which attempt it is on, are true but not
            // things the user can act on, and read as claims about their
            // situation: a neighbour's sensor rejecting the code is how the
            // run learns it is a neighbour, not a sign the code is wrong, and
            // a visible "attempt 2 of 3" invites cancelling to get a fresh
            // three, which throws the run's evidence away and restarts its
            // clock. That detail goes to the device log instead.
            return LocalizedString(
                "Checking the sensors in range. This can take a few minutes.",
                comment: "Pairing guidance while working through the sensors that have been found"
            )
        case .succeeded(_, _, let deviceName):
            return deviceName
        case .failed(let reason):
            return reason
        }
    }
}
