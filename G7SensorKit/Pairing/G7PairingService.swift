//
//  G7PairingService.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  Derived from DexKit by Erik Tolboom (https://github.com/nightscout/DexKit):
//  the pairing run follows its G7PairingRunner.
//

import CoreBluetooth
import Foundation
import os.log

public enum G7PairingState: Equatable {
    case idle
    /// Looking for sensors. `candidates` names the ones found so far.
    case scanning(candidates: [String])
    /// Running the handshake against `candidate`; `attempt` is 1-based.
    case authenticating(candidate: String, attempt: Int)
    /// Paired. `sharedKey` must be persisted: it is what lets reconnects skip
    /// the key exchange.
    case succeeded(peripheralIdentifier: UUID, sharedKey: Data, deviceName: String?)
    case failed(reason: String)

    public var isFinished: Bool {
        switch self {
        case .succeeded, .failed:
            return true
        case .idle, .scanning, .authenticating:
            return false
        }
    }
}

/// What a successful pairing run leaves for the session to take over: the
/// central it used and the connection it authenticated on.
public struct G7PairingHandoff {
    let bluetoothManager: G7BluetoothManager
    let peripheralManager: G7PeripheralManager
}

/// Pairs with a sensor: scan, connect to each plausible candidate in turn,
/// run the handshake, and hand back the key.
///
/// Runs on the session's own Bluetooth central when there is one (re-pairing
/// from settings), borrowing its delegate for the duration and giving it
/// back when done. There is exactly one central per app: a second could not
/// share the state-restoration identifier, and only the same central can
/// carry the authenticated connection straight into the session.
///
/// State changes are published on the main queue through `onStateChange`.
/// All of the service's own bookkeeping happens on the main queue too;
/// Bluetooth callbacks hop there first. That is not only for the UI's
/// benefit: `G7BluetoothManager.disconnectAll()` traps if called from the
/// Bluetooth queue, and the callbacks arrive on exactly that queue.
public final class G7PairingService {

    /// How long to look for a first candidate before giving up. A sensor
    /// another display used within the last ~15 minutes advertises only in a
    /// brief window around each 5-minute reading until that lease lapses, so
    /// the wait has to outlast the lease with room to spare. The screen shows
    /// the elapsed time and offers a way out throughout.
    public static let scanTimeout: TimeInterval = 20 * 60

    /// Connect-to-ready deadline for the candidate under trial.
    static let candidateTimeout: TimeInterval = 20

    /// Cap on one whole handshake attempt. The per-step deadline inside the
    /// authenticator is generous; this bounds the sum.
    static let authenticationTimeout: TimeInterval = 90

    private let log = OSLog(category: "G7PairingService")

    private let lockedState = Locked<G7PairingState>(.idle)

    public var state: G7PairingState {
        lockedState.value
    }

    /// Called on the main queue after every state change.
    public var onStateChange: ((G7PairingState) -> Void)?

    /// The radio's state, published on the main queue whenever it changes
    /// during a run. Pairing cannot proceed while Bluetooth is off or the
    /// app is not allowed to use it, and the run keeps waiting rather than
    /// failing, so the screen has to say why nothing is happening.
    public var onBluetoothStateChange: ((CBManagerState) -> Void)?

    public var bluetoothState: CBManagerState {
        bluetoothManager?.centralState ?? .unknown
    }

    /// Receives the handshake's step-by-step narration, for a device log or
    /// a diagnostics view. Never carries the code or key.
    public var onLog: ((String) -> Void)?

    private var pairingCode = ""
    private var expectedSerial: String?
    /// The sensor a session is already paired with, when re-pairing. It is
    /// never the one being replaced, and trying it costs a handshake that
    /// ends in a rejection.
    private var excludedPeripheralIdentifier: UUID?

    /// The session's central, when re-pairing; nil during first-time setup,
    /// where the run creates the central the new session will adopt.
    private let borrowedBluetoothManager: G7BluetoothManager?

    /// The slot this client takes on the sensor; also which slot's lease in
    /// an advertisement matters when ordering candidates.
    let displayType: G7DisplayType
    private weak var previousDelegate: G7BluetoothManagerDelegate?
    /// The sensor the borrowed central was following, to hand back if the
    /// run does not replace it.
    private var previousActiveIdentifier: UUID?

    /// When scanning began, for the elapsed time on screen.
    public private(set) var scanStartedAt: Date?

    private var bluetoothManager: G7BluetoothManager?
    /// The candidate that authenticated, kept connected for the hand-off.
    private var authenticatedPeripheralManager: G7PeripheralManager?
    private var planner = G7PairingPlanner()
    private var readyManagers: [UUID: G7PeripheralManager] = [:]

    private var authenticationInFlight = false
    /// Bumped whenever an in-flight handshake is disowned, so its late
    /// completion is ignored.
    private var authenticationGeneration = 0

    private var scanWatchdog: DispatchWorkItem?
    private var candidateWatchdog: DispatchWorkItem?
    private var authenticationWatchdog: DispatchWorkItem?

    /// - Parameter cgmManager: the manager being re-paired, if any. Its
    ///   session's central is borrowed for the run; with none, the run
    ///   creates the central the new session will adopt.
    public convenience init(cgmManager: G7CGMManager?, displayType: G7DisplayType = .phone) {
        self.init(bluetoothManager: cgmManager?.sensor.bluetoothManager, displayType: cgmManager?.displayType ?? displayType)
    }

    init(bluetoothManager: G7BluetoothManager?, displayType: G7DisplayType = .phone) {
        borrowedBluetoothManager = bluetoothManager
        self.displayType = displayType
    }

    /// After `.succeeded`: the central and connection for the session to take
    /// over. Clears the service's own claim on them, so a later `cancel()`
    /// does not tear down what the session is now using. Nil in the
    /// simulator, where nothing was connected.
    public func handOff() -> G7PairingHandoff? {
        guard case .succeeded = state,
              let bluetoothManager = bluetoothManager,
              let peripheralManager = authenticatedPeripheralManager
        else {
            return nil
        }
        self.bluetoothManager = nil
        authenticatedPeripheralManager = nil
        readyManagers.removeAll()
        return G7PairingHandoff(bluetoothManager: bluetoothManager, peripheralManager: peripheralManager)
    }

    private func setState(_ newState: G7PairingState) {
        lockedState.value = newState
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(newState)
        }
    }

    private var isRunActive: Bool {
        bluetoothManager != nil && !state.isFinished
    }

    /// Always asynchronous, never inline: `scanForPeripheral()` runs the
    /// manager's queue synchronously on the calling (main) thread, so a
    /// callback arriving inside it is on the main thread but on the manager
    /// queue, and running work inline there trips the manager's
    /// not-on-queue preconditions.
    private func onMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    // MARK: - Control

    /// Whether `code` has the shape of a G7 pairing code.
    public static func isValidPairingCode(_ code: String) -> Bool {
        code.count == 4 && code.allSatisfy(\.isNumber)
    }

    /// Whether a scanned `serial` can narrow the scan.
    ///
    /// A sensor advertises a CRC16 of its serial's digits, never the serial
    /// itself, so knowing the serial lets the run skip every sensor whose
    /// advertisement cannot produce that CRC. A serial that is not plain
    /// ASCII digits has no CRC to compare and narrows nothing, and the
    /// screen must not claim a filter that is not running. Narrowing is all
    /// it is: a CRC collision is possible, and an advertisement without
    /// manufacturer data is kept either way, so the handshake still decides.
    public static func canFilterBySerial(_ serial: String) -> Bool {
        G7Advertisement.serialChecksum(for: serial) != nil
    }

    /// Starts pairing with `pairingCode`. `serial` is the package serial when
    /// the code came from a scan; candidates that cannot have that serial
    /// are then skipped rather than tried.
    public func start(pairingCode: String, serial: String? = nil, excludingPeripheral excluded: UUID? = nil) {
        cancel()

        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard G7PairingService.isValidPairingCode(code) else {
            setState(.failed(reason: LocalizedString(
                "The pairing code is the 4-digit number printed on the sensor applicator.",
                comment: "Pairing failure reason for a malformed G7 pairing code"
            )))
            return
        }
        self.pairingCode = code
        expectedSerial = serial
        excludedPeripheralIdentifier = excluded
        // A scan knows the serial and has filtered to the one sensor, so a
        // mismatch there is a wrong code and stops. Manual entry cannot tell
        // the intended sensor from a neighbour, so keep looking until the
        // scan deadline instead of failing on the first sensor that does not
        // match the code.
        planner = G7PairingPlanner(keepScanningWhenExhausted: serial == nil)

        #if targetEnvironment(simulator)
        startSimulatedRun()
        #else
        let manager = borrowedBluetoothManager ?? G7BluetoothManager()
        if manager === borrowedBluetoothManager {
            previousDelegate = manager.delegate
            previousActiveIdentifier = manager.activePeripheralIdentifier
            // Whatever the session was following is not what we are pairing,
            // and the central only scans while it has no active peripheral:
            // with one still held, disconnecting alone left it neither
            // retrieving nor scanning, and every re-pair "found no sensor".
            manager.disconnectAll()
            manager.forgetPeripheral()
        }
        manager.delegate = self
        manager.setActivePeripheralIdentifier(nil)
        bluetoothManager = manager

        scanStartedAt = Date()
        setState(.scanning(candidates: []))
        onBluetoothStateChange?(manager.centralState)
        manager.scanForPeripheral()

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, self.isRunActive, !self.authenticationInFlight else {
                return
            }
            // With nothing ever found, or every sensor tried and none the
            // code's, the deadline is where the run stops. A candidate still
            // mid-handshake at the deadline is left to its own timeout.
            if self.planner.candidates.isEmpty {
                self.fail(LocalizedString(
                    "No sensor was found in 20 minutes. Make sure the sensor is inserted and within range, and that no other phone or app is using it.",
                    comment: "Pairing failure reason when the scan for a G7 sensor times out"
                ))
            } else {
                self.fail(self.planner.exhaustionReason)
            }
        }
        scanWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + G7PairingService.scanTimeout, execute: watchdog)
        #endif
    }

    public func cancel() {
        scanWatchdog?.cancel()
        scanWatchdog = nil
        candidateWatchdog?.cancel()
        candidateWatchdog = nil
        authenticationWatchdog?.cancel()
        authenticationWatchdog = nil
        authenticationGeneration += 1
        authenticationInFlight = false

        releaseBluetoothManager()
        planner = G7PairingPlanner()
        expectedSerial = nil
        excludedPeripheralIdentifier = nil
        setState(.idle)
    }

    /// Lets go of the central after a run that did not hand off: a borrowed
    /// one goes back to the session (which resumes on its next scan), an
    /// owned one is dropped. Either way every candidate is disconnected.
    private func releaseBluetoothManager() {
        guard let manager = bluetoothManager else {
            return
        }
        manager.disconnectAll()
        if manager === borrowedBluetoothManager {
            // Hand the central back to the session and re-arm it on its own
            // sensor; otherwise readings stop until something else prompts a
            // scan.
            manager.delegate = previousDelegate
            manager.setActivePeripheralIdentifier(previousActiveIdentifier)
            manager.scanForPeripheral()
        } else {
            manager.delegate = nil
        }
        bluetoothManager = nil
        authenticatedPeripheralManager = nil
        readyManagers.removeAll()
        scanStartedAt = nil
    }

    private func fail(_ reason: String) {
        setState(.failed(reason: reason))
        releaseBluetoothManager()
    }

    // MARK: - Simulator

    #if targetEnvironment(simulator)
    /// CoreBluetooth reports `.unsupported` in the simulator. Walk the same
    /// states with a stand-in sensor so onboarding can be exercised.
    private func startSimulatedRun() {
        // Set here too: the real path sets it alongside the scan it starts,
        // which this stands in for, and without it the screen's elapsed timer
        // never appears in the simulator.
        scanStartedAt = Date()
        setState(.scanning(candidates: []))
        let name = "DXCM" + pairingCode.suffix(2)
        let authenticate = DispatchWorkItem { [weak self] in
            guard let self = self, !self.state.isFinished else { return }
            self.setState(.authenticating(candidate: name, attempt: 1))
            let succeed = DispatchWorkItem { [weak self] in
                guard let self = self, !self.state.isFinished else { return }
                self.setState(.succeeded(
                    peripheralIdentifier: UUID(),
                    sharedKey: G7JPAKE.secureRandomBytes(16),
                    deviceName: "Dexcom" + self.pairingCode.suffix(2)
                ))
            }
            self.scanWatchdog = succeed
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: succeed)
        }
        scanWatchdog = authenticate
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: authenticate)
    }
    #endif

    // MARK: - Candidate handling

    private func armCandidateWatchdog() {
        guard candidateWatchdog == nil,
              !authenticationInFlight,
              let candidate = planner.currentCandidate,
              readyManagers[candidate.id] == nil
        else {
            return
        }
        let id = candidate.id
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.candidateWatchdog = nil
            guard self.isRunActive,
                  !self.authenticationInFlight,
                  self.planner.currentCandidate?.id == id,
                  self.readyManagers[id] == nil
            else {
                return
            }
            self.log.default("Candidate %{public}@ did not become ready in time", id.uuidString)
            self.report("Candidate \(candidate.name) did not connect in time")
            self.handleCandidateFailure()
        }
        candidateWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + G7PairingService.candidateTimeout, execute: watchdog)
    }

    private func cancelCandidateWatchdog() {
        candidateWatchdog?.cancel()
        candidateWatchdog = nil
    }

    private func authenticateCurrentCandidate() {
        guard isRunActive,
              !authenticationInFlight,
              let candidate = planner.currentCandidate,
              let peripheralManager = readyManagers[candidate.id]
        else {
            return
        }

        authenticationInFlight = true
        let attempt = planner.nextAttemptNumber
        setState(.authenticating(candidate: candidate.name, attempt: attempt))
        report("Trying \(candidate.name), attempt \(attempt)")

        cancelCandidateWatchdog()
        authenticationWatchdog?.cancel()
        authenticationGeneration += 1
        let generation = authenticationGeneration

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.authenticationWatchdog = nil
            guard self.isRunActive,
                  self.authenticationInFlight,
                  generation == self.authenticationGeneration,
                  self.planner.currentCandidate?.id == candidate.id
            else {
                return
            }
            self.report("\(candidate.name) attempt \(attempt) exceeded the time limit")
            self.authenticationGeneration += 1
            self.authenticationInFlight = false
            self.readyManagers.removeValue(forKey: candidate.id)
            self.bluetoothManager?.disconnectAll()
            self.handleCandidateFailure()
        }
        authenticationWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + G7PairingService.authenticationTimeout, execute: watchdog)

        let authenticator = G7Authenticator(
            pairingCode: pairingCode,
            storedSharedKey: nil,
            stepTimeout: G7Authenticator.pairingStepTimeout,
            displayType: displayType
        )
        authenticator.logHandler = { [weak self] message in
            self?.onMain { self?.onLog?(message) }
        }

        authenticator.authenticate(peripheralManager: peripheralManager) { [weak self] result in
            self?.onMain {
                guard let self = self, self.isRunActive, generation == self.authenticationGeneration else {
                    return
                }
                self.authenticationWatchdog?.cancel()
                self.authenticationWatchdog = nil
                self.authenticationInFlight = false

                switch result {
                case .success(let authResult):
                    // The connection stays up for the session to adopt; only
                    // the other candidates are let go. Terminal state first,
                    // so their disconnects are not scored as failures.
                    self.authenticatedPeripheralManager = peripheralManager
                    self.setState(.succeeded(
                        peripheralIdentifier: candidate.id,
                        sharedKey: authResult.sharedKey,
                        deviceName: authResult.deviceName
                    ))
                    self.bluetoothManager?.adoptAsActive(peripheralManager)
                case .failure(let error):
                    self.report("\(candidate.name) attempt \(attempt) failed: \(error)")
                    self.handleCandidateFailure(error: error)
                }
            }
        }
    }

    private func handleCandidateFailure(error: Error? = nil) {
        let action: G7PairingPlanner.Action
        switch error {
        case G7AuthenticatorError.rejected?:
            // Terminal for this sensor, and retrying invites the lockout.
            action = planner.abandonCurrentCandidate(reason: String(describing: error!))
        case G7AuthenticatorError.challengeMismatch?:
            // Proof that this sensor does not belong to the entered code.
            action = planner.abandonCurrentCandidate(reason: String(describing: error!))
        default:
            action = planner.recordFailure()
        }

        switch action {
        case .retryCurrent:
            guard let candidate = planner.currentCandidate,
                  let peripheralManager = readyManagers[candidate.id]
            else {
                bluetoothManager?.disconnectAll()
                bluetoothManager?.scanForPeripheral()
                armCandidateWatchdog()
                return
            }
            if peripheralManager.peripheral.state == .connected {
                authenticateCurrentCandidate()
            } else {
                readyManagers.removeValue(forKey: candidate.id)
                bluetoothManager?.disconnectAll()
                bluetoothManager?.scanForPeripheral()
                armCandidateWatchdog()
            }

        case .advanceToNext:
            setState(.scanning(candidates: planner.candidates.map(\.name)))
            if planner.currentCandidate.flatMap({ readyManagers[$0.id] }) != nil {
                authenticateCurrentCandidate()
            } else {
                bluetoothManager?.scanForPeripheral()
                armCandidateWatchdog()
            }

        case .keepScanning:
            // Manual entry: the sensors seen so far are not the code's, but the
            // intended one may not have advertised yet. Keep looking until the
            // scan watchdog's deadline rather than failing now.
            setState(.scanning(candidates: planner.candidates.map(\.name)))
            report("None of the sensors seen so far match the code; still scanning")
            bluetoothManager?.disconnectAll()
            bluetoothManager?.scanForPeripheral()

        case .giveUp(let reason):
            fail(reason)
        }
    }

    private func report(_ message: String) {
        log.default("%{public}@", message)
        onLog?(message)
    }
}

extension G7PairingService: G7BluetoothManagerDelegate {

    func bluetoothManager(_ manager: G7BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) -> PeripheralConnectionCommand {
        // A finished run must never connect again: the sensor it just paired
        // belongs to the session manager now.
        guard !state.isFinished,
              let advertisement = G7Advertisement(peripheral: peripheral, advertisementData: advertisementData),
              advertisement.isSupportedSensor
        else {
            return .ignore
        }

        if peripheral.identifier == excludedPeripheralIdentifier {
            return .ignore
        }

        if let serial = expectedSerial, !advertisement.couldHaveSerial(serial) {
            log.debug("Skipping %{public}@: not the scanned sensor", advertisement.name)
            return .ignore
        }

        // CoreBluetooth reports 127 when it cannot read the signal; only a
        // real (negative dBm) reading orders candidates by proximity.
        let signal = rssi.intValue < 0 ? rssi.intValue : G7PairingPlanner.unknownRSSI
        let id = peripheral.identifier
        onMain { [weak self] in
            guard let self = self, self.isRunActive else { return }
            let isHeld = advertisement.isSlotHeld(for: displayType) ?? false
            if self.planner.addCandidate(id: id, name: advertisement.name, isPhoneSlotHeld: isHeld, rssi: signal) {
                self.report(isHeld
                    ? "Found \(advertisement.name); another phone connected recently, so trying others first"
                    : "Found \(advertisement.name)")
                if case .scanning = self.state {
                    self.setState(.scanning(candidates: self.planner.candidates.map(\.name)))
                }
            } else if self.planner.updateSlot(id: id, isPhoneSlotHeld: advertisement.isSlotHeld(for: displayType), rssi: signal) {
                self.report("\(advertisement.name) advertisement updated")
            }
            self.armCandidateWatchdog()
        }
        return .connect
    }

    func bluetoothManagerShouldAcceptRestoredPeripherals(_ manager: G7BluetoothManager) -> Bool {
        // A stale restored peripheral would masquerade as a candidate.
        return false
    }

    func bluetoothManager(_ manager: G7BluetoothManager, readied peripheralManager: G7PeripheralManager) -> Bool {
        let id = peripheralManager.peripheral.identifier
        onMain { [weak self] in
            guard let self = self, self.isRunActive else { return }
            self.readyManagers[id] = peripheralManager
            if self.planner.currentCandidate?.id == id {
                self.authenticateCurrentCandidate()
            }
        }
        // Keep scanning: other candidates may still be in range.
        return false
    }

    func bluetoothManager(_ manager: G7BluetoothManager, readyingFailed peripheralManager: G7PeripheralManager, with error: Error) {
        log.default("Candidate connection failed: %{public}@", String(describing: error))
        onMain { [weak self] in
            guard let self = self, self.isRunActive, !self.authenticationInFlight else { return }
            self.handleCandidateFailure()
        }
    }

    func peripheralDidDisconnect(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, wasRemoteDisconnect: Bool) {
        let id = peripheralManager.peripheral.identifier
        onMain { [weak self] in
            guard let self = self, self.isRunActive, self.planner.currentCandidate?.id == id else { return }
            self.readyManagers.removeValue(forKey: id)
            if self.authenticationInFlight {
                // The sensor drops the link itself a few seconds after the
                // bond request, with the handshake complete and the key
                // installed; the authenticator reports that as success once
                // it notices. Its verdict decides, not the disconnect. A drop
                // earlier in the handshake ends in its step timeout instead.
                self.report("Link dropped during the handshake; waiting for the handshake's verdict")
                return
            }
            self.handleCandidateFailure()
        }
    }

    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveControlResponse response: Data) {}

    func bluetoothManager(_ manager: G7BluetoothManager, didReceiveBackfillResponse response: Data) {}

    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveAuthenticationResponse response: Data) {}

    func bluetoothManagerScanningStatusDidChange(_ manager: G7BluetoothManager) {
        // Off the manager's queue: `isScanning` syncs onto it.
        onMain { [weak self] in
            guard let self = self, self.isRunActive else { return }
            self.report(manager.isScanning ? "Scanning for sensors" : "Stopped scanning")
            self.onBluetoothStateChange?(manager.centralState)
        }
    }
}
