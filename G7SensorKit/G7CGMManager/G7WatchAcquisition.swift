//
//  G7WatchAcquisition.swift
//  G7SensorKit
//
//  watchOS target only. The watch app sleeps between readings, its background scanning is
//  rationed, and a reconnect into the sensor's advertising tail counts against it, so the stock
//  rescan after every close does not work there. G7BluetoothManager hands its acquisition steps
//  to this arm; elsewhere there is no arm and the stock steps run.
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import os.log

/// The watch's one acquisition design: a single daemon-held request per burst, re-lodged after each
/// close by holding the process 35 s past link-up, then a plain connect (measured 33 in 33). State
/// restoration relaunches the app for each link. Runs on the bluetooth manager's queue.
public final class G7WatchAcquisition: G7AcquisitionArm {
    /// Link-up → the ~3.5-s read, the sensor's close, and its 20–24-s advertising tail all sit inside
    /// 35 s. A request that lands after this never reconnects into the tail.
    public static let tailClearanceSeconds: TimeInterval = 35
    /// The sensor's own cadence: one reading every 300 s.
    public static let period: TimeInterval = 300
    public static let missedBurstsBeforeBootstrap = 3
    /// One full window plus jitter: a scan pass that cannot span a burst proves nothing.
    public static let bootstrapScanCap: TimeInterval = 330
    /// OmnipodKit's heartbeatFailureBackoffSeconds.
    public static let refusalBackoffSeconds: TimeInterval = 30
    /// A didFailToConnect this soon after the call is the daemon declining the request itself.
    public static let synchronousRefusalWindow: TimeInterval = 2

    /// How long the hold keeps the process, counted from link-up; never below half a second.
    public static func holdWait(sinceLinkUp: TimeInterval) -> TimeInterval {
        max(0.5, tailClearanceSeconds - sinceLinkUp)
    }
    /// The hold before the next plain connect; nil = past the clearance, nothing to wait for.
    public static func relodgeHold(sinceLinkUp: TimeInterval) -> TimeInterval? {
        sinceLinkUp < tailClearanceSeconds ? holdWait(sinceLinkUp: sinceLinkUp) : nil
    }
    public enum FailureAction: Equatable { case backOff(TimeInterval), relodge }
    /// A synchronous refusal waits before asking again. A late failure (the request went live and
    /// could not connect) re-lodges through the arm.
    public static func onConnectFailure(sinceLodge: TimeInterval) -> FailureAction {
        sinceLodge < synchronousRefusalWindow ? .backOff(refusalBackoffSeconds) : .relodge
    }
    /// Whole bursts elapsed since `reference` (the last reading, or the last bootstrap pass).
    public static func missedBursts(since reference: Date?, now: Date = Date()) -> Int {
        reference.map { max(0, Int(now.timeIntervalSince($0) / period)) } ?? 0
    }

    private unowned let manager: G7BluetoothManager
    private let log = OSLog(category: "G7BluetoothManager")

    /// didConnect stamp; the tail clearance counts from here.
    private var linkUpAt: Date?
    /// Exactly one daemon-held request in flight.
    private var lodged = false
    private var lodgedAt: Date?
    /// A hold-then-connect is running; its end lodges.
    private var holdPending = false
    /// The one scan pass.
    private var bootstrapPass = false
    private var bootstrapTimer: DispatchSourceTimer?
    /// When the last bootstrap pass started: a silent sensor is scanned for once per three bursts.
    private var lastBootstrapAt: Date?
    /// The last reading's sensor timestamp, for the 3-miss test. Seeded at launch from the
    /// manager's persisted `latestReadingTimestamp`.
    private var lastReadingAt: Date?

    init(manager: G7BluetoothManager) {
        self.manager = manager
    }

    private var central: CBCentralManager { manager.centralManager }
    private var queue: DispatchQueue { manager.managerQueue }

    private func watchLog(_ line: String) {
        log.default("[g7-watch] %{public}@", line)
        manager.delegate?.bluetoothManager(manager, logEvent: "[g7-watch] " + line)      // into the host's device log
    }

    // MARK: - Hooks

    /// The stock scan entry on the watch (poweredOn, resumeScanning, after a forget or a bootstrap
    /// pass).
    func scan() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard central.state == .poweredOn else { return }
        guard let id = manager.activePeripheralIdentifier,
              let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first else {
            startBootstrapPass(reason: "no adopted peripheral")
            return
        }
        adopt(peripheral)
        // Three bursts missed with a request standing: presume the identifier stale and scan once.
        // A pass restarts the count, so an absent sensor is scanned for once per three bursts.
        let reference = [lastReadingAt, lastBootstrapAt].compactMap { $0 }.max()
        let missed = G7WatchAcquisition.missedBursts(since: reference)
        if !bootstrapPass, peripheral.state != .connected, missed >= G7WatchAcquisition.missedBurstsBeforeBootstrap {
            if peripheral.state == .connecting { central.cancelPeripheralConnection(peripheral) }
            lodged = false; lodgedAt = nil
            startBootstrapPass(reason: "\(missed) bursts missed on the lodged request")
            return
        }
        let sinceLinkUp = linkUpAt.map { Date().timeIntervalSince($0) } ?? .infinity
        relodge(peripheral, sinceLinkUp: sinceLinkUp, why: "acquisition armed")
    }

    func found(_ peripheral: CBPeripheral) {
        lodge(peripheral, why: "adopted on discovery")   // handles .connecting/.connected/no-code
    }

    func connected(_ peripheral: CBPeripheral) {
        let waited = lodgedAt.map { Date().timeIntervalSince($0) }
        lodged = false; lodgedAt = nil
        linkUpAt = Date()
        if bootstrapPass { endBootstrapPass(reason: "connected") }
        watchLog(String(format: "link up %@ %@ · pid %d", peripheral.name ?? "unnamed",
                        waited.map { String(format: "%.0f s after the lodge", $0) } ?? "(restored launch)",
                        ProcessInfo.processInfo.processIdentifier))
    }

    /// Returns true when the arm owns what happens next (the adopted sensor closed the link).
    func disconnected(_ peripheral: CBPeripheral, error: Error?) -> Bool {
        guard peripheral.identifier == manager.activePeripheralIdentifier else { return false }
        let sinceLinkUp = linkUpAt.map { Date().timeIntervalSince($0) } ?? 0
        linkUpAt = nil; lodged = false; lodgedAt = nil
        guard !bootstrapPass else { return false }
        let code = (error as NSError?).map { " [\($0.domain)#\($0.code)] \($0.localizedDescription)" } ?? ""
        relodge(peripheral, sinceLinkUp: sinceLinkUp, why: String(format: "sensor closed %.1f s after link-up%@", sinceLinkUp, code))
        return true
    }

    func failedToConnect(_ peripheral: CBPeripheral, error: Error?) -> Bool {
        guard lodged, peripheral.identifier == manager.activePeripheralIdentifier else { return false }
        lodged = false
        let sinceLodge = lodgedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        lodgedAt = nil
        let code = (error as NSError?).map { "\($0.domain)#\($0.code) \($0.localizedDescription)" } ?? "no error"
        switch G7WatchAcquisition.onConnectFailure(sinceLodge: sinceLodge) {
        case .backOff(let s):
            watchLog(String(format: "REFUSED %.2f s after the lodge (%@) — lodging again in %.0f s", sinceLodge, code, s))
            let id = peripheral.identifier
            queue.asyncAfter(deadline: .now() + s) { [weak self] in
                guard let self, !self.lodged,
                      let p = self.central.retrievePeripherals(withIdentifiers: [id]).first, p.state == .disconnected else { return }
                self.lodge(p, why: "after the refusal backoff")
            }
        case .relodge:
            watchLog(String(format: "connect failed %.0f s after the lodge (%@) — re-lodging", sinceLodge, code))
            relodge(peripheral, sinceLinkUp: 0, why: "after a late connect failure")
        }
        return true
    }

    /// The daemon drops every request with the radio: a request still believed lodged would block
    /// the next lodge until the 3-miss test, and a scan the next one. Start clean at poweredOn.
    func radioDown() {
        lodged = false; lodgedAt = nil; linkUpAt = nil
        bootstrapPass = false
        bootstrapTimer?.cancel(); bootstrapTimer = nil
    }

    /// An already-connected peripheral gets no second didConnect: run that path now so the
    /// handshake starts on the link the system brought us back for.
    func restored(_ peripheral: CBPeripheral) {
        if peripheral.state == .connected { manager.centralManager(central, didConnect: peripheral) }
    }

    func noteReading(at timestamp: Date) {
        lastReadingAt = timestamp
    }

    // MARK: - The request

    private func adopt(_ peripheral: CBPeripheral) {
        if let pm = manager.activePeripheralManager { pm.peripheral = peripheral } else {
            manager.activePeripheralManager = G7PeripheralManager(peripheral: peripheral, configuration: .dexcomG7, centralManager: central)
            manager.activePeripheralManager?.delegate = manager
        }
        manager.managedPeripherals[peripheral.identifier] = manager.activePeripheralManager
    }

    /// Every close, late connect failure and wake: hold the process until the sensor's tail has
    /// cleared, then a plain connect. A `sinceLinkUp` of 0 counts the tail clearance from now.
    private func relodge(_ peripheral: CBPeripheral, sinceLinkUp: TimeInterval, why: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !lodged, !holdPending else { return }
        guard let wait = G7WatchAcquisition.relodgeHold(sinceLinkUp: sinceLinkUp) else {
            // A wake past the clearance: nothing to wait for, a plain request now.
            lodge(peripheral, why: "\(why) · nothing to wait for")
            return
        }
        holdPending = true
        watchLog(String(format: "%@ · holding the process %.1f s past the sensor's tail, then a plain connect", why, wait))
        holdProcess(reason: "G7 re-lodge after the sensor's tail", upTo: wait) { [weak self] systemEnded in
            self?.queue.async {
                guard let self else { return }
                self.holdPending = false
                self.lodge(peripheral, why: systemEnded ? "hold ended by the system" : "hold over")
            }
        }
    }

    /// ONE plain connect with the daemon. Never held, never withdrawn by us.
    private func lodge(_ peripheral: CBPeripheral, why: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard central.state == .poweredOn, !lodged else { return }
        switch peripheral.state {
        case .connected:     return
        case .connecting:
            // Not ours (ours sets `lodged`): a restored request bluetoothd no longer held cost eight hours
            // with no link (2026-09-16). Cancel it and lodge our own; the timer covers a silent cancel.
            watchLog("restored as connecting with no request of ours — cancelling it and lodging a fresh connect")
            central.cancelPeripheralConnection(peripheral)
            let id = peripheral.identifier
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.lodged,
                      let p = self.central.retrievePeripherals(withIdentifiers: [id]).first, p.state == .disconnected else { return }
                self.lodge(p, why: "after cancelling a restored connect the daemon did not hold")
            }
            return
        case .disconnecting: return   // the close callback lodges: a connect issued during a cancel is lost inside CoreBluetooth
        default:             break
        }
        if let delegate = manager.delegate, !delegate.bluetoothManagerCanAuthenticate(manager) {
            // A link we cannot authenticate is one the sensor closes unencrypted ~10 s later — a
            // tally count every burst for nothing. Stand down until a configuration brings a code.
            manager.setNeedsCodeForSensor(peripheral.name ?? "sensor")
            watchLog("no pairing code for \(peripheral.name ?? "sensor") — not lodging")
            return
        }
        manager.setNeedsCodeForSensor(nil)
        lodged = true; lodgedAt = Date()
        central.connect(peripheral, options: nil)
        watchLog("lodged — \(why) · the app may suspend")
    }

    /// performExpiringActivity, once-only: `onEnd` runs when `wait` elapses, when the system ends the
    /// hold, or when the returned release closure is called — whichever first, exactly once.
    @discardableResult
    private func holdProcess(reason: String, upTo wait: TimeInterval, onEnd: @escaping (_ systemEnded: Bool) -> Void = { _ in }) -> () -> Void {
        let gate = DispatchSemaphore(value: 0)
        let once = NSLock(); var done = false
        let end: (Bool) -> Void = { s in once.lock(); let first = !done; done = true; once.unlock(); if first { onEnd(s) } }
        DispatchQueue.global(qos: .userInitiated).async {
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
                if expired { end(true); gate.signal(); return }
                _ = gate.wait(timeout: .now() + wait); end(false)
            }
        }
        return { gate.signal() }
    }

    // MARK: - Bootstrap: the one scan pass (fresh install / sensor change / 3 misses)

    private func startBootstrapPass(reason: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard central.state == .poweredOn, !bootstrapPass else { return }
        bootstrapPass = true
        lastBootstrapAt = Date()
        // With no identifier there is nothing else to fall back on, so the scan stays up until the
        // sensor is found. With one, a short pass and then the daemon-held connect is the better bet.
        let untilFound = manager.activePeripheralIdentifier == nil
        watchLog(untilFound
                 ? "BOOTSTRAP scan — \(reason) (no identifier yet: scanning until the sensor is found)"
                 : "BOOTSTRAP scan pass — \(reason) (one pass, \(Int(G7WatchAcquisition.bootstrapScanCap)) s cap)")
        let services = [SensorServiceUUID.advertisement.cbUUID, SensorServiceUUID.cgmService.cbUUID]
        for p in central.retrieveConnectedPeripherals(withServices: services) { manager.handleDiscoveredPeripheral(p) }
        central.registerForConnectionEvents(options: [CBConnectionEventMatchingOption.serviceUUIDs: services])
        central.scanForPeripherals(withServices: [SensorServiceUUID.advertisement.cbUUID], options: nil)
        manager.delegate?.bluetoothManagerScanningStatusDidChange(manager)
        guard !untilFound else {
            manager.setIsSearchingForSensor(true)
            return
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + G7WatchAcquisition.bootstrapScanCap)
        t.setEventHandler { [weak self] in self?.endBootstrapPass(reason: "cap reached") }
        t.resume()
        bootstrapTimer = t
    }

    private func endBootstrapPass(reason: String) {
        guard bootstrapPass else { return }
        bootstrapPass = false
        bootstrapTimer?.cancel(); bootstrapTimer = nil
        manager.managerQueue_stopScanning()
        manager.setIsSearchingForSensor(false)
        watchLog("bootstrap pass over — \(reason)")
        guard reason != "connected" else { return }
        if let p = manager.activePeripheral, p.state == .connecting { central.cancelPeripheralConnection(p); lodged = false; lodgedAt = nil }
        // Nothing adopted: stand down until the next wake (poweredOn / foreground / the phone's code).
        if manager.activePeripheralIdentifier != nil { scan() }
    }
}

/// Direct read on the watch: Loop's own handshake, no Dexcom app needed. The pairing code is entered
/// on the phone and reaches the watch in the manager's exported configuration (`sharedState`).
public enum G7WatchDirectRead {
    /// Glance note while the watch scans for a sensor it has never connected to.
    public static func searchingNote(_ searching: Bool) -> String? {
        searching ? "Looking for your sensor — keep Loop open on your watch until it connects." : nil
    }

    /// Glance note while a code is missing.
    public static func needsCodeNote(for sensor: String?) -> String? {
        sensor.map { "Sensor code needed for \($0) — enter it in Loop ▸ Dexcom G7 on the phone (it is shown in the Dexcom app)." }
    }
}
