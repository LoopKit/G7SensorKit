//
//  G7JPAKE.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CryptoKit
import Foundation

enum G7JPAKEError: Error {
    /// `makeRound3` or `deriveSharedKey` was called before both of our own
    /// ephemeral keypairs existed.
    case outOfOrder
}

/// Client side of the password-authenticated key exchange a G7-family sensor
/// runs during pairing: an EC-JPAKE over P-256 whose low-entropy secret is
/// the 4-digit code printed on the sensor's applicator.
///
/// The exchange proves both sides know the code without either sending it,
/// and ends with a 256-bit agreed secret whose first 16 bytes become the
/// AES-128 key that authenticates every later reconnect.
///
/// Deviations from textbook EC-JPAKE, all of them things the sensor requires:
/// the party identifiers are fixed strings, the round-3 proof uses a fixed
/// randomizer rather than a fresh one, and the transcript hash covers
/// length-prefixed uncompressed points in a specific order.
final class G7JPAKE {

    typealias RandomBytesGenerator = (Int) -> Data

    /// Party identifier attached to proofs we generate.
    private static let ownParty = Array("client".utf8)

    /// Party identifier attached to proofs the sensor generates.
    private static let peerParty: [UInt8] = [0x37, 0x56, 0x27, 0x67, 0x56, 0x27]

    /// The randomizer the sensor expects in our round-3 proof. Fixed, not
    /// drawn fresh: the sensor reproduces this value when it verifies.
    private static let round3Randomizer = G7BigUInt(bigEndianBytes: Data(hexadecimalString:
        "fbc971b837e9491e45a4179ed33865c508a1e0a1d350f5af0f96370695fdc393")!)

    /// The pairing code as a big-endian integer over its ASCII digits.
    private let pin: G7BigUInt
    private let random: RandomBytesGenerator

    private var keyPair1: (privateKey: G7BigUInt, publicKey: G7P256Point)?
    private var keyPair2: (privateKey: G7BigUInt, publicKey: G7P256Point)?

    init(pairingCode: String, random: @escaping RandomBytesGenerator = G7JPAKE.secureRandomBytes) {
        pin = G7BigUInt(bigEndianBytes: Data(pairingCode.utf8))
        self.random = random
    }

    static func secureRandomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            // SecRandomCopyBytes does not fail in practice; if it ever did,
            // silently continuing with a weak nonce would be worse than a
            // crash during pairing.
            preconditionFailure("SecRandomCopyBytes failed with \(status)")
        }
        return Data(bytes)
    }

    // MARK: - Our rounds

    /// Our first ephemeral keypair, encoded for the wire.
    func makeRound1() -> Data {
        let pair = makeKeyPair()
        keyPair1 = pair
        return makeCert(base: G7P256.generator, publicKey: pair.publicKey, privateKey: pair.privateKey).encoded
    }

    /// Our second ephemeral keypair, encoded for the wire.
    func makeRound2() -> Data {
        let pair = makeKeyPair()
        keyPair2 = pair
        return makeCert(base: G7P256.generator, publicKey: pair.publicKey, privateKey: pair.privateKey).encoded
    }

    /// Our key-confirmation round, computed over both of the sensor's rounds.
    func makeRound3(peerRound1: G7PCert, peerRound2: G7PCert) throws -> Data {
        guard let keyPair1 = keyPair1, let keyPair2 = keyPair2 else {
            throw G7JPAKEError.outOfOrder
        }
        let blindedKey = G7BigUInt.mulMod(keyPair2.privateKey, pin, G7P256.order)
        let base = G7P256.add(
            G7P256.add(keyPair1.publicKey, peerRound1.publicKey),
            peerRound2.publicKey
        )
        let publicKey = G7P256.multiply(base, by: blindedKey)
        return makeCert(
            base: base,
            publicKey: publicKey,
            privateKey: blindedKey,
            randomizer: G7JPAKE.round3Randomizer
        ).encoded
    }

    /// The agreed secret: SHA-256 of the x-coordinate of the shared point.
    /// The first 16 bytes are the AES-128 session key.
    func deriveSharedSecret(peerRound2: G7PCert, peerRound3: G7PCert) throws -> Data {
        guard let keyPair2 = keyPair2 else {
            throw G7JPAKEError.outOfOrder
        }
        // Strip our own blinding from the sensor's confirmation value, then
        // apply our round-2 private key to land on the shared point.
        let blindedKey = G7BigUInt.mulMod(keyPair2.privateKey, pin, G7P256.order)
        let unblind = G7BigUInt.subMod(.zero, blindedKey, G7P256.order)
        let shared = G7P256.multiply(
            G7P256.add(peerRound3.publicKey, G7P256.multiply(peerRound2.publicKey, by: unblind)),
            by: keyPair2.privateKey
        )
        return Data(SHA256.hash(data: shared.x.bigEndianBytes(paddedTo: 32)))
    }

    // MARK: - Verifying the sensor's proofs

    /// Whether a round-1 or round-2 cert from the sensor carries a valid
    /// proof. Advisory: a sensor that fails this still pairs, and the AES
    /// challenge later in the handshake is the real gate, so callers log
    /// rather than abort.
    func validateRound1Or2(_ cert: G7PCert) -> Bool {
        verifyProof(base: G7P256.generator, cert: cert, party: G7JPAKE.peerParty)
    }

    /// Whether the sensor's round-3 cert carries a valid proof. Advisory,
    /// same as `validateRound1Or2`.
    func validateRound3(peerRound1: G7PCert, peerRound3: G7PCert) -> Bool {
        guard let keyPair1 = keyPair1, let keyPair2 = keyPair2 else {
            return false
        }
        let base = G7P256.add(
            G7P256.add(keyPair1.publicKey, keyPair2.publicKey),
            peerRound1.publicKey
        )
        return verifyProof(base: base, cert: peerRound3, party: G7JPAKE.peerParty)
    }

    // MARK: - Internals

    private func makeKeyPair() -> (privateKey: G7BigUInt, publicKey: G7P256Point) {
        let privateKey = randomScalar()
        return (privateKey, G7P256.multiplyGenerator(by: privateKey))
    }

    /// Uniform in [1, order - 2], the range the sensor's own implementation uses.
    private func randomScalar() -> G7BigUInt {
        let upper = G7P256.order - G7BigUInt(2)
        return G7BigUInt(bigEndianBytes: random(32)).modulo(upper) + .one
    }

    private func makeCert(
        base: G7P256Point,
        publicKey: G7P256Point,
        privateKey: G7BigUInt,
        randomizer: G7BigUInt? = nil
    ) -> G7PCert {
        let randomizer = randomizer ?? randomScalar()
        let proofPoint = G7P256.multiply(base, by: randomizer)
        let challenge = transcriptHash(base: base, proofPoint: proofPoint, publicKey: publicKey, party: G7JPAKE.ownParty)
        let proof = G7BigUInt.subMod(
            randomizer,
            G7BigUInt.mulMod(challenge, privateKey, G7P256.order),
            G7P256.order
        )
        return G7PCert(publicKey: publicKey, proofPoint: proofPoint, proof: proof)
    }

    /// Schnorr verification: `base * proof + publicKey * challenge` must
    /// reproduce the committed proof point.
    private func verifyProof(base: G7P256Point, cert: G7PCert, party: [UInt8]) -> Bool {
        let challenge = transcriptHash(
            base: base,
            proofPoint: cert.proofPoint,
            publicKey: cert.publicKey,
            party: party
        )
        let recomputed = G7P256.add(
            G7P256.multiply(base, by: cert.proof),
            G7P256.multiply(cert.publicKey, by: challenge)
        )
        return recomputed == cert.proofPoint
    }

    /// SHA-256 over the three points and the party identifier, each prefixed
    /// with its 4-byte big-endian length, reduced into the scalar field.
    private func transcriptHash(
        base: G7P256Point,
        proofPoint: G7P256Point,
        publicKey: G7P256Point,
        party: [UInt8]
    ) -> G7BigUInt {
        var buffer = Data()
        for point in [base, proofPoint, publicKey] {
            appendLengthPrefixed([UInt8](point.uncompressedBytes), to: &buffer)
        }
        appendLengthPrefixed(party, to: &buffer)
        return G7BigUInt(bigEndianBytes: Data(SHA256.hash(data: buffer))).modulo(G7P256.order)
    }

    private func appendLengthPrefixed(_ bytes: [UInt8], to buffer: inout Data) {
        buffer.appendBigEndian(UInt32(bytes.count))
        buffer.append(contentsOf: bytes)
    }
}
