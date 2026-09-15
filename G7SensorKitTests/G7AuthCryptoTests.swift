//
//  G7AuthCryptoTests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CryptoKit
import XCTest
@testable import G7SensorKit

class G7AESTests: XCTestCase {

    /// Vectors generated with `openssl enc -aes-128-ecb -nopad`, so they are
    /// independent of this implementation.
    func testKnownAnswers() throws {
        let cases: [(challenge: String, key: String, expected: String)] = [
            ("0011223344556677", "000102030405060708090a0b0c0d0e0f", "28b454bdf4d00600"),
            ("a1b2c3d4e5f60718", "ffeeddccbbaa99887766554433221100", "19b22de101061935")
        ]
        for testCase in cases {
            let result = try G7AES.encryptChallenge(
                Data(hexadecimalString: testCase.challenge)!,
                key: Data(hexadecimalString: testCase.key)!
            )
            XCTAssertEqual(result.hexadecimalString, testCase.expected)
        }
    }

    func testOutputIsEightBytes() throws {
        let result = try G7AES.encryptChallenge(
            Data(repeating: 0xAB, count: 8),
            key: Data(repeating: 0x11, count: 16)
        )
        XCTAssertEqual(result.count, 8)
    }

    func testRejectsWrongLengths() {
        XCTAssertThrowsError(try G7AES.encryptChallenge(Data(repeating: 0, count: 7), key: Data(repeating: 0, count: 16)))
        XCTAssertThrowsError(try G7AES.encryptChallenge(Data(repeating: 0, count: 8), key: Data(repeating: 0, count: 15)))
    }

    /// Different keys must give different answers, which is the property the
    /// handshake relies on to detect a wrong pairing code.
    func testKeySensitivity() throws {
        let challenge = Data(repeating: 0x5A, count: 8)
        let a = try G7AES.encryptChallenge(challenge, key: Data(repeating: 0x01, count: 16))
        let b = try G7AES.encryptChallenge(challenge, key: Data(repeating: 0x02, count: 16))
        XCTAssertNotEqual(a, b)
    }
}

class G7ChallengeSignerTests: XCTestCase {

    func testEmbeddedKeyPairIsConsistent() throws {
        let privateKey = try P256.Signing.PrivateKey(rawRepresentation: G7DexcomCredentials.challengePrivateKey)
        XCTAssertEqual(privateKey.publicKey.x963Representation, G7DexcomCredentials.challengePublicKey)
        XCTAssertEqual(G7ChallengeSigner.publicKey, G7DexcomCredentials.challengePublicKey)
    }

    func testSignatureVerifiesAgainstTheEmbeddedPublicKey() throws {
        // A 0x0C acknowledgement: opcode, status, then the 16 bytes to sign.
        var acknowledgement = Data([0x0C, 0x00])
        acknowledgement.append(Data((0 ..< 16).map { UInt8($0) }))

        let signature = try G7ChallengeSigner.sign(challengeAcknowledgement: acknowledgement)
        XCTAssertEqual(signature.count, 64)

        let publicKey = try P256.Signing.PublicKey(x963Representation: G7DexcomCredentials.challengePublicKey)
        let parsed = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        XCTAssertTrue(publicKey.isValidSignature(parsed, for: acknowledgement[2 ..< 18]))
    }

    func testSignsOnlyTheSixteenPayloadBytes() throws {
        // Trailing bytes beyond the payload must not change the signature's
        // validity over those 16 bytes.
        var short = Data([0x0C, 0x00])
        short.append(Data((0 ..< 16).map { UInt8($0) }))
        let long = short + Data([0xDE, 0xAD, 0xBE, 0xEF])

        let publicKey = try P256.Signing.PublicKey(x963Representation: G7DexcomCredentials.challengePublicKey)
        let signature = try P256.Signing.ECDSASignature(
            rawRepresentation: G7ChallengeSigner.sign(challengeAcknowledgement: long)
        )
        XCTAssertTrue(publicKey.isValidSignature(signature, for: short[2 ..< 18]))
    }

    func testRejectsShortAcknowledgement() {
        XCTAssertThrowsError(try G7ChallengeSigner.sign(challengeAcknowledgement: Data(repeating: 0, count: 17)))
    }
}

class G7DexcomCredentialsTests: XCTestCase {

    /// Guards against a transcription slip in the embedded blobs: a DER
    /// certificate declares its own length in its header.
    func testCertificatesAreWellFormedDER() {
        let certificates = G7DexcomCredentials.certificates
        XCTAssertEqual(certificates.count, 2)
        XCTAssertEqual(certificates.map(\.count), [494, 465])

        for certificate in certificates {
            let bytes = [UInt8](certificate)
            XCTAssertEqual(bytes[0], 0x30, "not a DER SEQUENCE")
            XCTAssertEqual(bytes[1], 0x82, "expected a two-byte length")
            let declared = Int(bytes[2]) << 8 | Int(bytes[3])
            XCTAssertEqual(declared + 4, certificate.count, "DER length disagrees with the blob")
        }
    }

    func testLeafCertificateCarriesTheChallengePublicKey() {
        let leaf = G7DexcomCredentials.certificates[1].hexadecimalString
        XCTAssertTrue(leaf.contains(G7DexcomCredentials.challengePublicKey.hexadecimalString))
    }

    func testPrivateKeyIsPaddedToThirtyTwoBytes() {
        XCTAssertEqual(G7DexcomCredentials.challengePrivateKey.count, 32)
        XCTAssertEqual(G7DexcomCredentials.challengePrivateKey.first, 0x00)
    }
}
