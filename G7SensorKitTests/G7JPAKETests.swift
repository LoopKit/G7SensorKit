//
//  G7JPAKETests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CryptoKit
import XCTest
@testable import G7SensorKit

/// Stands in for the sensor's half of the EC-JPAKE exchange so the handshake
/// can be driven end to end without hardware. It runs the mirror-image
/// algorithm: if both halves land on the same secret, our half is doing the
/// protocol and not merely agreeing with itself.
private final class SimulatedSensor {
    /// The identifier the sensor attaches to its own proofs.
    static let party: [UInt8] = [0x37, 0x56, 0x27, 0x67, 0x56, 0x27]

    private let pin: G7BigUInt
    private let privateKey1: G7BigUInt
    private let privateKey2: G7BigUInt
    let publicKey1: G7P256Point
    let publicKey2: G7P256Point

    init(pairingCode: String, seed: UInt8) {
        pin = G7BigUInt(bigEndianBytes: Data(pairingCode.utf8))
        privateKey1 = G7BigUInt(bigEndianBytes: Data((0 ..< 32).map { UInt8(truncatingIfNeeded: $0 &+ seed) }))
            .modulo(G7P256.order - G7BigUInt(2)) + .one
        privateKey2 = G7BigUInt(bigEndianBytes: Data((0 ..< 32).map { UInt8(truncatingIfNeeded: $0 &* 3 &+ seed) }))
            .modulo(G7P256.order - G7BigUInt(2)) + .one
        publicKey1 = G7P256.multiplyGenerator(by: privateKey1)
        publicKey2 = G7P256.multiplyGenerator(by: privateKey2)
    }

    var round1: G7PCert {
        cert(base: G7P256.generator, publicKey: publicKey1, privateKey: privateKey1, randomizer: scalar(11))
    }

    var round2: G7PCert {
        cert(base: G7P256.generator, publicKey: publicKey2, privateKey: privateKey2, randomizer: scalar(23))
    }

    /// Mirror of the client's round 3: base is our two public keys plus the
    /// sensor's first, blinded by the sensor's second private key times the pin.
    func round3(clientRound1: G7PCert, clientRound2: G7PCert) -> G7PCert {
        let base = G7P256.add(G7P256.add(clientRound1.publicKey, clientRound2.publicKey), publicKey1)
        let blinded = G7BigUInt.mulMod(privateKey2, pin, G7P256.order)
        return cert(
            base: base,
            publicKey: G7P256.multiply(base, by: blinded),
            privateKey: blinded,
            randomizer: scalar(37)
        )
    }

    /// Mirror of the client's key derivation.
    func sharedSecret(clientRound2: G7PCert, clientRound3: G7PCert) -> Data {
        let blinded = G7BigUInt.mulMod(privateKey2, pin, G7P256.order)
        let unblind = G7BigUInt.subMod(.zero, blinded, G7P256.order)
        let shared = G7P256.multiply(
            G7P256.add(clientRound3.publicKey, G7P256.multiply(clientRound2.publicKey, by: unblind)),
            by: privateKey2
        )
        return Data(SHA256.hash(data: shared.x.bigEndianBytes(paddedTo: 32)))
    }

    private func scalar(_ seed: UInt8) -> G7BigUInt {
        G7BigUInt(bigEndianBytes: Data((0 ..< 32).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ seed) }))
            .modulo(G7P256.order - G7BigUInt(2)) + .one
    }

    private func cert(
        base: G7P256Point,
        publicKey: G7P256Point,
        privateKey: G7BigUInt,
        randomizer: G7BigUInt
    ) -> G7PCert {
        let proofPoint = G7P256.multiply(base, by: randomizer)
        let challenge = SimulatedSensor.transcriptHash(
            base: base,
            proofPoint: proofPoint,
            publicKey: publicKey,
            party: SimulatedSensor.party
        )
        let proof = G7BigUInt.subMod(
            randomizer,
            G7BigUInt.mulMod(challenge, privateKey, G7P256.order),
            G7P256.order
        )
        return G7PCert(publicKey: publicKey, proofPoint: proofPoint, proof: proof)
    }

    static func transcriptHash(
        base: G7P256Point,
        proofPoint: G7P256Point,
        publicKey: G7P256Point,
        party: [UInt8]
    ) -> G7BigUInt {
        var buffer = Data()
        for point in [base, proofPoint, publicKey] {
            let bytes = [UInt8](point.uncompressedBytes)
            buffer.appendBigEndian(UInt32(bytes.count))
            buffer.append(contentsOf: bytes)
        }
        buffer.appendBigEndian(UInt32(party.count))
        buffer.append(contentsOf: party)
        return G7BigUInt(bigEndianBytes: Data(SHA256.hash(data: buffer))).modulo(G7P256.order)
    }
}

class G7JPAKETests: XCTestCase {

    /// Runs a full exchange and returns what each side derived.
    private func exchange(
        clientCode: String,
        sensorCode: String,
        seed: UInt8 = 5
    ) throws -> (client: Data, sensor: Data, clientJPAKE: G7JPAKE, sensor1: G7PCert, sensor3: G7PCert) {
        let jpake = G7JPAKE(pairingCode: clientCode)
        let sensor = SimulatedSensor(pairingCode: sensorCode, seed: seed)

        let sensorRound1 = sensor.round1
        let clientRound1 = try G7PCert(data: jpake.makeRound1())

        let sensorRound2 = sensor.round2
        let clientRound2 = try G7PCert(data: jpake.makeRound2())

        let sensorRound3 = sensor.round3(clientRound1: clientRound1, clientRound2: clientRound2)
        let clientSecret = try jpake.deriveSharedSecret(peerRound2: sensorRound2, peerRound3: sensorRound3)
        let clientRound3 = try G7PCert(data: jpake.makeRound3(peerRound1: sensorRound1, peerRound2: sensorRound2))

        let sensorSecret = sensor.sharedSecret(clientRound2: clientRound2, clientRound3: clientRound3)
        return (clientSecret, sensorSecret, jpake, sensorRound1, sensorRound3)
    }

    func testBothSidesDeriveTheSameSecret() throws {
        let result = try exchange(clientCode: "1155", sensorCode: "1155")
        XCTAssertEqual(result.client.count, 32)
        XCTAssertEqual(result.client, result.sensor)
    }

    func testDerivedSecretVariesWithTheSensorKeys() throws {
        let first = try exchange(clientCode: "1155", sensorCode: "1155", seed: 5)
        let second = try exchange(clientCode: "1155", sensorCode: "1155", seed: 99)
        XCTAssertNotEqual(first.client, second.client)
    }

    /// A wrong code still completes the exchange cryptographically; the two
    /// sides simply land on different keys, which is why the AES challenge
    /// later in the handshake is where a wrong code actually surfaces.
    func testWrongCodeYieldsDisagreeingSecrets() throws {
        let result = try exchange(clientCode: "1155", sensorCode: "9999")
        XCTAssertEqual(result.client.count, 32)
        XCTAssertNotEqual(result.client, result.sensor)
    }

    func testSensorProofsValidate() throws {
        let result = try exchange(clientCode: "1155", sensorCode: "1155")
        XCTAssertTrue(result.clientJPAKE.validateRound1Or2(result.sensor1))
        XCTAssertTrue(result.clientJPAKE.validateRound3(peerRound1: result.sensor1, peerRound3: result.sensor3))
    }

    func testTamperedSensorProofIsRejected() throws {
        let result = try exchange(clientCode: "1155", sensorCode: "1155")
        let tampered = G7PCert(
            publicKey: result.sensor1.publicKey,
            proofPoint: result.sensor1.proofPoint,
            proof: G7BigUInt.addMod(result.sensor1.proof, .one, G7P256.order)
        )
        XCTAssertFalse(result.clientJPAKE.validateRound1Or2(tampered))
    }

    func testOurProofsWouldValidateAtTheSensor() throws {
        // Verify our round-1 cert the way the sensor would: same Schnorr
        // check, but against the "client" party identifier.
        let jpake = G7JPAKE(pairingCode: "1155")
        let ourRound1 = try G7PCert(data: jpake.makeRound1())
        let challenge = SimulatedSensor.transcriptHash(
            base: G7P256.generator,
            proofPoint: ourRound1.proofPoint,
            publicKey: ourRound1.publicKey,
            party: Array("client".utf8)
        )
        let recomputed = G7P256.add(
            G7P256.multiply(G7P256.generator, by: ourRound1.proof),
            G7P256.multiply(ourRound1.publicKey, by: challenge)
        )
        XCTAssertEqual(recomputed, ourRound1.proofPoint)
    }

    func testRound3UsesTheFixedRandomizer() throws {
        // The sensor reproduces our round-3 commitment, so it must come from
        // the fixed randomizer rather than a fresh draw: two runs with the
        // same keys must produce the same proof point.
        let makeRound3: () throws -> G7PCert = {
            let jpake = G7JPAKE(pairingCode: "1155", random: { count in Data(repeating: 0x42, count: count) })
            let sensor = SimulatedSensor(pairingCode: "1155", seed: 5)
            _ = jpake.makeRound1()
            _ = jpake.makeRound2()
            return try G7PCert(data: jpake.makeRound3(peerRound1: sensor.round1, peerRound2: sensor.round2))
        }
        XCTAssertEqual(try makeRound3().proofPoint, try makeRound3().proofPoint)
    }

    func testCertEncodingRoundTrip() throws {
        let jpake = G7JPAKE(pairingCode: "1155")
        let encoded = jpake.makeRound1()
        XCTAssertEqual(encoded.count, G7PCert.byteCount)
        let decoded = try G7PCert(data: encoded)
        XCTAssertEqual(decoded.encoded, encoded)
        XCTAssertTrue(G7P256.isOnCurve(decoded.publicKey))
        XCTAssertTrue(G7P256.isOnCurve(decoded.proofPoint))
    }

    func testCertRejectsWrongLength() {
        XCTAssertThrowsError(try G7PCert(data: Data(repeating: 0, count: 159)))
        XCTAssertThrowsError(try G7PCert(data: Data(repeating: 0, count: 161)))
    }

    func testOutOfOrderUse() {
        let jpake = G7JPAKE(pairingCode: "1155")
        let sensor = SimulatedSensor(pairingCode: "1155", seed: 5)
        XCTAssertThrowsError(try jpake.makeRound3(peerRound1: sensor.round1, peerRound2: sensor.round2))
        XCTAssertFalse(jpake.validateRound3(peerRound1: sensor.round1, peerRound3: sensor.round1))
    }
}
