//
//  G7ShareUploader.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import os.log

/// What the uploader last did, for the settings screen.
public struct G7ShareUploadStatus: Equatable {
    public var lastUploadAt: Date?
    public var lastError: String?
    public var lastErrorAt: Date?
    public var pendingCount: Int = 0

    public init(lastUploadAt: Date? = nil, lastError: String? = nil, lastErrorAt: Date? = nil, pendingCount: Int = 0) {
        self.lastUploadAt = lastUploadAt
        self.lastError = lastError
        self.lastErrorAt = lastErrorAt
        self.pendingCount = pendingCount
    }
}

/// Sends readings to Dexcom Share as they arrive. It posts first and only
/// signs in, starts a monitoring session or registers the sensor as the
/// account's device when the service refuses for that reason. Readings
/// that could not be sent wait for the next attempt, up to a day's worth.
final class G7ShareUploader {
    private let log = OSLog(category: "G7ShareUploader")
    private let queue = DispatchQueue(label: "org.loopkit.G7SensorKit.share")

    private let client: G7ShareClient
    private var pending: [G7ShareReading] = []
    private var uploadedThrough: Date?
    /// The serial last registered as the account's device, so a refusal for
    /// it is not answered by registering it again. Kept until relaunch or a
    /// new sign-in: if the Dexcom app takes the account's device back, we
    /// let it rather than taking turns with it.
    private var assignedSerial: String?
    private var task: Task<Void, Never>?
    private(set) var status = G7ShareUploadStatus()

    /// The sensor's serial, which the service knows the readings by.
    var serial: String?

    /// Called on `queue` whenever `status` or `uploadedThrough` changes.
    var onStatusChange: ((G7ShareUploadStatus, Date?) -> Void)?
    var onLog: ((String) -> Void)?

    static let maximumPending = 288
    static let batchSize = 50
    /// After a refusal that a retry will not fix, wait this long before
    /// trying again on a new reading.
    static let errorBackoff: TimeInterval = 15 * 60
    private var backoffUntil: Date?

    init(client: G7ShareClient, uploadedThrough: Date?) {
        self.client = client
        self.uploadedThrough = uploadedThrough
    }

    func enqueue(_ readings: [G7ShareReading]) {
        queue.async {
            let cutoff = self.uploadedThrough ?? .distantPast
            let new = readings.filter { $0.date > cutoff && !self.pending.contains($0) }
            guard !new.isEmpty else { return }
            self.pending.append(contentsOf: new)
            self.pending.sort { $0.date < $1.date }
            if self.pending.count > G7ShareUploader.maximumPending {
                self.pending.removeFirst(self.pending.count - G7ShareUploader.maximumPending)
            }
            self.status.pendingCount = self.pending.count
            self.onStatusChange?(self.status, self.uploadedThrough)
            self.uploadIfNeeded()
        }
    }

    /// Runs one upload attempt now, e.g. after signing in.
    func uploadNow() {
        queue.async {
            self.backoffUntil = nil
            self.uploadIfNeeded()
        }
    }

    private func uploadIfNeeded() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard task == nil, !pending.isEmpty, let serial = serial else { return }
        if let backoffUntil = backoffUntil, backoffUntil > Date() { return }
        let batch = Array(pending.prefix(G7ShareUploader.batchSize))
        task = Task {
            let result = await self.upload(batch, serial: serial)
            self.queue.async {
                self.task = nil
                switch result {
                case .success:
                    self.pending.removeAll { $0.date <= batch.last!.date }
                    self.uploadedThrough = max(self.uploadedThrough ?? .distantPast, batch.last!.date)
                    self.status.lastUploadAt = Date()
                    self.status.lastError = nil
                    self.status.lastErrorAt = nil
                    self.status.pendingCount = self.pending.count
                    self.onLog?("Uploaded \(batch.count) reading(s) to Dexcom Share")
                    self.onStatusChange?(self.status, self.uploadedThrough)
                    self.uploadIfNeeded()
                case .failure(let error):
                    self.status.lastError = error.localizedDescription
                    self.status.lastErrorAt = Date()
                    self.status.pendingCount = self.pending.count
                    self.backoffUntil = Date().addingTimeInterval(G7ShareUploader.errorBackoff)
                    self.onLog?("Dexcom Share upload failed: \((error as? G7ShareError)?.logDescription ?? error.localizedDescription)")
                    self.onStatusChange?(self.status, self.uploadedThrough)
                }
            }
        }
    }

    private enum Recovery {
        case signIn
        case startMonitoring
        case assignReceiver
    }

    /// Posts, answering each refusal with its recovery, including a refusal of
    /// a recovery itself (a monitoring session refused because the sensor is
    /// not registered yet). Each recovery runs once per attempt, except that a
    /// new registration may need a new monitoring session.
    private func upload(_ batch: [G7ShareReading], serial: String) async -> Result<Void, Error> {
        var attempted: Set<Recovery> = []
        var next: Recovery?
        while true {
            do {
                if let recovery = next {
                    next = nil
                    try await perform(recovery, serial: serial)
                    if recovery == .assignReceiver {
                        attempted.remove(.startMonitoring)
                    }
                    continue
                }
                try await post(batch, serial: serial)
                return .success(())
            } catch let error as G7ShareError {
                guard let recovery = recovery(for: error, serial: serial), attempted.insert(recovery).inserted else {
                    return .failure(error)
                }
                next = recovery
            } catch {
                return .failure(error)
            }
        }
    }

    private func recovery(for error: G7ShareError, serial: String) -> Recovery? {
        if error.isSessionExpired {
            return .signIn
        }
        if error.serviceCode == G7ShareError.monitoringSessionNotActive {
            return .startMonitoring
        }
        if error.isReceiverRefused, assignedSerial != serial {
            return .assignReceiver
        }
        return nil
    }

    private func perform(_ recovery: Recovery, serial: String) async throws {
        switch recovery {
        case .signIn:
            client.forgetSession()
            try await client.signIn()
        case .startMonitoring:
            do {
                try await client.startRemoteMonitoringSession(serial: serial)
            } catch let error as G7ShareError where error.isMonitoringSessionAlreadyActive {
                // Started by someone else in the meantime; fine.
            }
        case .assignReceiver:
            onLog?("Registering sensor \(serial) as the Dexcom Share device")
            try await client.assignReceiver(serial: serial)
            assignedSerial = serial
        }
    }

    private func post(_ batch: [G7ShareReading], serial: String) async throws {
        do {
            try await client.postReadings(batch, serial: serial)
        } catch let error as G7ShareError where error.serviceCode == G7ShareError.duplicateEgvPosted {
            // Already there; as good as sent.
        }
    }
}
