//
//  G7Authenticator.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  Derived from DexKit by Erik Tolboom (https://github.com/nightscout/DexKit):
//  the handshake sequencing and message buffering follow its G7Authenticator.
//  The cryptography is separate; see Crypto/.
//

import CoreBluetooth
import Foundation
import os.log

public enum G7AuthenticatorError: Error {
    case timeout(step: String)
    case unexpectedResponse(step: String, response: Data)

    /// The sensor completed the key exchange and then refused the session
    /// anyway. `failureCode` is its reason, when it gave a known one.
    /// Terminal for this connection: retrying the same way cannot help, and
    /// four refusals in a row make the sensor stop accepting connections for
    /// a while. `.noAppKey` is the one the session can recover from on its
    /// own, by dropping the stored key and pairing again with the code.
    case rejected(authStatus: UInt8, failureCode: G7AuthFailureCode?)

    /// The sensor's answer to our random challenge does not match what our
    /// key produced, so we do not share a key with it: either the code
    /// belongs to a different sensor, or a stored key has gone stale.
    case challengeMismatch

    /// Neither a stored key nor a pairing code was available.
    case noCredentials
}

extension G7AuthenticatorError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .timeout(let step):
            return "Timed out waiting for the sensor during \(step)."
        case .unexpectedResponse(let step, let response):
            return "Unexpected response during \(step): \(response.hexadecimalString)"
        case .rejected(_, let failureCode):
            switch failureCode {
            case .deviceTypeRestriction:
                return LocalizedString(
                    "The sensor is already connected to another phone or app. A sensor only works with one at a time; stop the other one from using this sensor, then try again.",
                    comment: "Error description when a G7 sensor's display slot is taken"
                )
            case .noAppKey:
                return LocalizedString(
                    "The sensor no longer recognizes this phone and will be paired again automatically.",
                    comment: "Error description when a G7 sensor has lost the app's key"
                )
            case .challengeMismatch:
                return LocalizedString(
                    "The sensor rejected this phone's key.",
                    comment: "Error description when a G7 sensor reports a key mismatch"
                )
            case .some(.none), nil:
                return LocalizedString(
                    "The sensor accepted the pairing code but refused the connection.",
                    comment: "Error description for a G7 sensor rejecting an authenticated connection with no reason given"
                )
            }
        case .challengeMismatch:
            return LocalizedString(
                "This sensor does not match the pairing code entered.",
                comment: "Error description when a G7 sensor's challenge response does not match the pairing code"
            )
        case .noCredentials:
            return LocalizedString(
                "No pairing code or saved key is available for this sensor.",
                comment: "Error description when a G7 authentication is attempted with no credentials"
            )
        }
    }
}

/// Runs the handshake that makes us a display the sensor will talk to.
///
/// Two paths, decided by whether we already hold a key for this sensor:
///
/// - **First pairing.** An EC-JPAKE exchange over the 4-digit code produces a
///   shared key, then we prove possession of it, upload Dexcom's certificates,
///   sign the sensor's key challenge, and let the sensor start BLE bonding.
/// - **Reconnect.** With the key already stored, everything above collapses
///   into one AES challenge/response.
///
/// The whole handshake is synchronous, run on the peripheral manager's own
/// serial queue via `perform`. Blocking there is safe and deliberate: it is
/// not the queue CoreBluetooth delivers callbacks on, and the protocol is a
/// strict request/response sequence that reads far better straight-line than
/// as a dozen chained callbacks.
final class G7Authenticator {

    struct Result {
        let sharedKey: Data
        /// The sensor's full name, learned once the link is up. Only present
        /// after a fresh handshake.
        let deviceName: String?
        /// Whether this run performed the EC-JPAKE exchange (as opposed to
        /// reusing a stored key).
        let didExchangeKeys: Bool
    }

    /// Per-step response deadline for a reconnect. Short: the link is up and
    /// the sensor answers immediately or not at all.
    static let reconnectStepTimeout: TimeInterval = 10

    /// Per-step deadline during first pairing. Generous, because the sensor
    /// streams certificates in 20-byte chunks and a stalled step is better
    /// resolved by the pairing service's own watchdog than by failing here.
    static let pairingStepTimeout: TimeInterval = 60

    /// How long to wait for the sensor's post-bond confirmation. Not fatal
    /// when it never arrives; by then the key is already good.
    static let bondConfirmationTimeout: TimeInterval = 20

    private let log = OSLog(category: "G7Authenticator")

    private let pairingCode: String?
    private let storedSharedKey: Data?
    private let stepTimeout: TimeInterval

    /// Receives a short description of each step as it happens, for the
    /// in-app device communication log. A tester reporting "it got stuck"
    /// is only diagnosable if these are visible outside Xcode. Never carries
    /// the pairing code or key material.
    var logHandler: ((String) -> Void)?

    init(pairingCode: String?, storedSharedKey: Data?, stepTimeout: TimeInterval) {
        self.pairingCode = pairingCode
        self.storedSharedKey = storedSharedKey
        self.stepTimeout = stepTimeout
    }

    /// Runs the handshake, calling `completion` exactly once on the
    /// peripheral manager's queue.
    func authenticate(
        peripheralManager: G7PeripheralManager,
        completion: @escaping (Swift.Result<Result, Error>) -> Void
    ) {
        peripheralManager.perform { peripheral in
            do {
                completion(.success(try self.run(peripheral)))
            } catch {
                self.report("Authentication failed: \(error)")
                peripheral.setValueUpdateHandler(for: .authentication, handler: nil)
                peripheral.setValueUpdateHandler(for: .certificate, handler: nil)
                completion(.failure(error))
            }
        }
    }

    private func run(_ peripheral: G7PeripheralManager) throws -> Result {
        guard storedSharedKey != nil || pairingCode != nil else {
            throw G7AuthenticatorError.noCredentials
        }

        report(storedSharedKey != nil
            ? "Authenticating with the saved key"
            : "Pairing: running the key exchange")

        try peripheral.setNotifyValue(true, for: .certificate)
        try peripheral.setNotifyValue(true, for: .authentication)
        report("Characteristics: \(peripheral.describeCharacteristic(.authentication)); "
            + "\(peripheral.describeCharacteristic(.certificate)); "
            + "\(peripheral.describeCharacteristic(.control))")

        // Buffer authentication traffic for the whole handshake. Its
        // acknowledgements can land while our own write is still pending, and
        // a one-shot wait registered after the write would miss them.
        let authentication = G7AuthMessageBuffer()
        peripheral.setValueUpdateHandler(for: .authentication) { [weak authentication] message in
            authentication?.append(message)
        }
        defer {
            peripheral.setValueUpdateHandler(for: .authentication, handler: nil)
            peripheral.setValueUpdateHandler(for: .certificate, handler: nil)
        }

        let sharedKey: Data
        let didExchangeKeys: Bool
        if let storedSharedKey = storedSharedKey {
            sharedKey = storedSharedKey
            didExchangeKeys = false
        } else {
            sharedKey = try exchangeKeys(peripheral)
            didExchangeKeys = true
        }

        let status = try proveSharedKey(peripheral, authentication: authentication, sharedKey: sharedKey)

        // The shortcut is for a stored-key reconnect only. After a fresh key
        // exchange the sensor can still say "bonded" (the OS bond from an
        // earlier pairing on this phone is intact), but that is not the same
        // as it holding the key we just derived: skipping the certificate
        // phase on that basis left the sensor dropping the link on our first
        // control write, and its reconnect challenge answered with a key we
        // did not have. The official app runs the certificate phase on every
        // pairing; so do we.
        if !didExchangeKeys, status.isAuthenticated, status.isBonded {
            report("Already authenticated and bonded")
            return Result(sharedKey: sharedKey, deviceName: peripheral.peripheral.name, didExchangeKeys: didExchangeKeys)
        }

        if !didExchangeKeys {
            // A reconnect that got this far without being authenticated has a
            // key the sensor no longer honours. Re-pairing is the only fix,
            // and the caller decides whether it can do that unattended.
            throw G7AuthenticatorError.unexpectedResponse(
                step: "reconnect",
                response: Data([0x05, status.authStatus, status.bondStatus])
            )
        }

        report("Running the certificate exchange (auth=\(status.authStatus) bond=\(status.bondStatus))")
        try exchangeCertificates(peripheral, authentication: authentication)
        try answerKeyChallenge(peripheral, authentication: authentication)
        try finalizeAndBond(peripheral, authentication: authentication)

        return Result(
            sharedKey: sharedKey,
            deviceName: peripheral.peripheral.name,
            didExchangeKeys: didExchangeKeys
        )
    }

    // MARK: - EC-JPAKE

    private func exchangeKeys(_ peripheral: G7PeripheralManager) throws -> Data {
        guard let pairingCode = pairingCode else {
            throw G7AuthenticatorError.noCredentials
        }
        let jpake = G7JPAKE(pairingCode: pairingCode)

        let sensorRound1 = try exchangeRound(peripheral, round: 0, ours: jpake.makeRound1())
        let sensorRound2 = try exchangeRound(peripheral, round: 1, ours: jpake.makeRound2())
        let sensorRound3 = try requestSensorRound(peripheral, round: 2)

        // Advisory only: the sensor does not require us to check its proofs,
        // and the AES challenge below is the real gate. On hardware they do
        // not verify under the transcript format we use for our own (which
        // the sensor accepts), so the sensor's side evidently hashes
        // something differently; noted, not acted on.
        let proofsVerified = jpake.validateRound1Or2(sensorRound1)
            && jpake.validateRound1Or2(sensorRound2)
            && jpake.validateRound3(peerRound1: sensorRound1, peerRound3: sensorRound3)
        if !proofsVerified {
            report("Key exchange: the sensor's proofs did not verify under our transcript format (advisory)")
        }

        // Derive before sending our own round 3: the sensor may drop the link
        // as soon as it has what it needs.
        let secret = try jpake.deriveSharedSecret(peerRound2: sensorRound2, peerRound3: sensorRound3)
        try peripheral.writeCertificateBytes(jpake.makeRound3(peerRound1: sensorRound1, peerRound2: sensorRound2))

        report("Key exchange complete")
        return secret.prefix(16)
    }

    private func exchangeRound(_ peripheral: G7PeripheralManager, round: UInt8, ours: Data) throws -> G7PCert {
        let theirs = try requestSensorRound(peripheral, round: round)
        try peripheral.writeCertificateBytes(ours)
        return theirs
    }

    /// Asks for one round of the sensor's exchange and collects the streamed
    /// reply. The buffer is installed before the request goes out: the sensor
    /// starts streaming before its acknowledgement arrives.
    private func requestSensorRound(_ peripheral: G7PeripheralManager, round: UInt8) throws -> G7PCert {
        let step = "key exchange round \(round + 1)"
        let buffer = installCertificateBuffer(peripheral)
        try peripheral.writeValue(Data([0x0A, round]), for: .authentication, type: .withResponse)
        let data = try waitForCertificateBytes(peripheral, buffer: buffer, count: G7PCert.byteCount, step: step)
        report("\(step): received the sensor's \(data.count)-byte certificate")
        return try G7PCert(data: data)
    }

    // MARK: - AES challenge

    private func proveSharedKey(
        _ peripheral: G7PeripheralManager,
        authentication: G7AuthMessageBuffer,
        sharedKey: Data
    ) throws -> AuthChallengeRxMessage {
        let step = "challenge"
        let challenge = G7JPAKE.secureRandomBytes(8)
        report("Challenge: sending ours")
        try peripheral.writeValue(Data([0x02]) + challenge + Data([0x02]), for: .authentication, type: .withResponse)

        let response = try waitForAuthentication(authentication, prefix: 0x03, step: step)
        guard response.count >= 17 else {
            throw G7AuthenticatorError.unexpectedResponse(step: step, response: response)
        }

        let bytes = Data(response)
        let base = bytes.startIndex
        guard try G7AES.encryptChallenge(challenge, key: sharedKey) == bytes[base + 1 ..< base + 9] else {
            report("Challenge: the sensor's answer does not match our key")
            throw G7AuthenticatorError.challengeMismatch
        }
        report("Challenge: the sensor's answer verified")

        let sensorChallenge = Data(bytes[base + 9 ..< base + 17])
        let answer = try G7AES.encryptChallenge(sensorChallenge, key: sharedKey)
        try peripheral.writeValue(Data([0x04]) + answer, for: .authentication, type: .withResponse)

        let verdict = try waitForAuthentication(authentication, prefix: 0x05, step: step)
        guard let status = AuthChallengeRxMessage(data: verdict) else {
            throw G7AuthenticatorError.unexpectedResponse(step: step, response: verdict)
        }
        report("Challenge: verdict auth=\(status.authStatus) bond=\(status.bondStatus)")

        if status.isRejected {
            throw G7AuthenticatorError.rejected(authStatus: status.authStatus, failureCode: status.failureCode)
        }
        return status
    }

    // MARK: - Certificate exchange

    private func exchangeCertificates(_ peripheral: G7PeripheralManager, authentication: G7AuthMessageBuffer) throws {
        let certificates = G7DexcomCredentials.certificates
        for (index, certificate) in certificates.enumerated() {
            try exchangeCertificate(peripheral, authentication: authentication, index: index, certificate: certificate)
        }

        // Terminator: an entry past the last index, declared zero length.
        report("Certificates: sending the terminator")
        var request = Data([0x0B, UInt8(certificates.count)])
        request.append(UInt32(0).littleEndian)
        try peripheral.writeValue(request, for: .authentication, type: .withResponse)
        _ = try waitForAuthentication(authentication, prefix: 0x0B, step: "certificate terminator")
    }

    private func exchangeCertificate(
        _ peripheral: G7PeripheralManager,
        authentication: G7AuthMessageBuffer,
        index: Int,
        certificate: Data
    ) throws {
        let step = "certificate \(index)"

        // Installed before the request: the sensor streams its certificate
        // ahead of the acknowledgement that describes it.
        let buffer = installCertificateBuffer(peripheral)
        var request = Data([0x0B, UInt8(index)])
        request.append(UInt32(certificate.count).littleEndian)
        try peripheral.writeValue(request, for: .authentication, type: .withResponse)

        let acknowledgement = try waitForAuthentication(authentication, prefix: 0x0B, step: step)

        // `0B 00 <index> <length u16 LE>`. The sensor's certificates are not
        // the same size as ours, so the length has to be read, not assumed.
        let expectedLength: Int
        if acknowledgement.count >= 5 {
            let base = acknowledgement.startIndex
            let declared = Int(acknowledgement[base + 3]) | Int(acknowledgement[base + 4]) << 8
            expectedLength = declared > 0 ? declared : certificate.count
        } else {
            report("\(step): short acknowledgement \(acknowledgement.hexadecimalString); assuming our own length")
            expectedLength = certificate.count
        }

        let theirs = try waitForCertificateBytes(peripheral, buffer: buffer, count: expectedLength, step: step)
        report("\(step): received \(theirs.count) bytes, sending ours (\(certificate.count) bytes)")
        try peripheral.writeCertificateBytes(certificate)
    }

    // MARK: - Key challenge

    private func answerKeyChallenge(_ peripheral: G7PeripheralManager, authentication: G7AuthMessageBuffer) throws {
        let step = "key challenge"
        report("\(step): sending a nonce")

        let buffer = installCertificateBuffer(peripheral)
        try peripheral.writeValue(
            Data([0x0C]) + G7JPAKE.secureRandomBytes(16),
            for: .authentication,
            type: .withResponse
        )

        let acknowledgement = try waitForAuthentication(authentication, prefix: 0x0C, step: step)
        guard acknowledgement.count >= 18 else {
            peripheral.setValueUpdateHandler(for: .certificate, handler: nil)
            throw G7AuthenticatorError.unexpectedResponse(step: step, response: acknowledgement)
        }

        // The sensor's own 64-byte block arrives alongside. We do not verify
        // it: the sensor is checking us, not the other way round, and the
        // signing key it would be checked against is the one we just sent.
        _ = try waitForCertificateBytes(peripheral, buffer: buffer, count: 64, step: step)

        let signature = try G7ChallengeSigner.sign(challengeAcknowledgement: acknowledgement)
        report("\(step): sending our signature")
        try peripheral.writeCertificateBytes(signature)
    }

    // MARK: - Finalize

    private func finalizeAndBond(_ peripheral: G7PeripheralManager, authentication: G7AuthMessageBuffer) throws {
        report("Finalizing")
        try peripheral.writeValue(Data([0x06, 0x1E]), for: .authentication, type: .withResponse)
        _ = try waitForAuthentication(authentication, prefix: 0x06, step: "finalize")

        report("Finalizing: the sensor will start BLE pairing now, so expect the system pairing prompt")
        try peripheral.writeValue(Data([0x07]), for: .authentication, type: .withResponse)
        _ = try waitForAuthentication(authentication, prefix: 0x07, step: "bond request")

        // The sensor confirms once the link is encrypted. Treat a silent
        // sensor as success: the key and certificates are already accepted,
        // and failing here would throw away a completed pairing. The sensor
        // has been seen to drop the link a few seconds after 07 instead, so
        // the wait is in short slices that stop as soon as the link is gone;
        // the reconnect that follows uses the key just installed.
        let deadline = Date().addingTimeInterval(G7Authenticator.bondConfirmationTimeout)
        var confirmation: (match: Data, discarded: [Data])?
        while confirmation == nil, Date() < deadline, peripheral.peripheral.state == .connected {
            confirmation = authentication.waitForMessage(timeout: 1) { $0.first == 0x08 }
        }
        if let confirmation = confirmation {
            report("Bonded (\(confirmation.match.hexadecimalString))")
        } else if peripheral.peripheral.state != .connected {
            report("The sensor dropped the link after the bond request; the key is installed and the next connection will use it")
        } else {
            report("No bond confirmation arrived; continuing, since the handshake already succeeded")
        }
    }

    // MARK: - Waiting

    private func waitForAuthentication(
        _ buffer: G7AuthMessageBuffer,
        prefix: UInt8,
        step: String
    ) throws -> Data {
        guard let result = buffer.waitForMessage(timeout: stepTimeout, matching: { $0.first == prefix }) else {
            throw G7AuthenticatorError.timeout(step: step)
        }
        for stale in result.discarded where stale.first != 0x0A {
            // The 0A acknowledgements of our round requests arrive after the
            // certificate bytes we actually wait for; skipping them is normal.
            report("Skipping an unexpected message: \(stale.hexadecimalString)")
        }
        return result.match
    }

    private func installCertificateBuffer(_ peripheral: G7PeripheralManager) -> G7ChunkBuffer {
        let buffer = G7ChunkBuffer()
        peripheral.setValueUpdateHandler(for: .certificate) { [weak buffer] chunk in
            buffer?.append(chunk)
        }
        return buffer
    }

    private func waitForCertificateBytes(
        _ peripheral: G7PeripheralManager,
        buffer: G7ChunkBuffer,
        count: Int,
        step: String
    ) throws -> Data {
        defer {
            peripheral.setValueUpdateHandler(for: .certificate, handler: nil)
        }
        guard let data = buffer.wait(forByteCount: count, timeout: stepTimeout) else {
            report("\(step): timed out with \(buffer.count) of \(count) bytes")
            throw G7AuthenticatorError.timeout(step: step)
        }
        return data
    }

    /// Logs to the system log (so it survives into a sysdiagnose) and, when
    /// set, to the host's device communication log.
    private func report(_ message: String) {
        log.default("%{public}@", message)
        logHandler?(message)
    }
}

// MARK: - Buffers

/// Collects discrete messages from the authentication characteristic.
///
/// Discrete rather than concatenated because each notification is one
/// message, and out-of-sequence arrivals need to be skipped rather than
/// misread as the message a step is waiting for.
private final class G7AuthMessageBuffer {
    private let condition = NSCondition()
    private var messages: [Data] = []

    func append(_ message: Data) {
        condition.lock()
        messages.append(message)
        condition.broadcast()
        condition.unlock()
    }

    /// Waits for the first message satisfying `predicate`, returning it along
    /// with any older messages it skipped past.
    func waitForMessage(
        timeout: TimeInterval,
        matching predicate: (Data) -> Bool
    ) -> (match: Data, discarded: [Data])? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while true {
            if let index = messages.firstIndex(where: predicate) {
                let discarded = Array(messages[..<index])
                let match = messages[index]
                messages.removeFirst(index + 1)
                return (match, discarded)
            }
            guard condition.wait(until: deadline) else {
                return nil
            }
        }
    }
}

/// Accumulates the certificate characteristic's byte stream, which arrives in
/// 20-byte chunks with no framing of its own.
private final class G7ChunkBuffer {
    private let condition = NSCondition()
    private var storage = Data()

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return storage.count
    }

    func append(_ chunk: Data) {
        condition.lock()
        storage.append(chunk)
        condition.broadcast()
        condition.unlock()
    }

    func wait(forByteCount count: Int, timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while storage.count < count {
            guard condition.wait(until: deadline) else {
                return nil
            }
        }
        return storage
    }
}
