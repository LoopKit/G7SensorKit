//
//  G7P256Tests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CryptoKit
import XCTest
@testable import G7SensorKit

/// CryptoKit can produce `k * G` for any scalar `k` (that is exactly what
/// deriving a P-256 public key is), which makes it an independent oracle for
/// this file's hand-rolled curve arithmetic.
class G7P256Tests: XCTestCase {

    /// A scalar in [1, n-1], plus the public key CryptoKit derives from it.
    private func randomScalarWithOracle() -> (scalar: G7BigUInt, x: G7BigUInt, y: G7BigUInt) {
        while true {
            let bytes = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
            guard let key = try? P256.Signing.PrivateKey(rawRepresentation: bytes) else {
                continue
            }
            let publicKey = key.publicKey.rawRepresentation
            return (
                G7BigUInt(bigEndianBytes: bytes),
                G7BigUInt(bigEndianBytes: publicKey.prefix(32)),
                G7BigUInt(bigEndianBytes: publicKey.suffix(32))
            )
        }
    }

    func testGeneratorIsOnCurve() {
        XCTAssertTrue(G7P256.isOnCurve(G7P256.generator))
    }

    func testKnownSmallMultiples() {
        // Published P-256 test vectors for 2G and 3G.
        let two = G7P256.multiplyGenerator(by: G7BigUInt(2))
        XCTAssertEqual(
            two.x.bigEndianBytes(paddedTo: 32).hexadecimalString.uppercased(),
            "7CF27B188D034F7E8A52380304B51AC3C08969E277F21B35A60B48FC47669978"
        )
        XCTAssertEqual(
            two.y.bigEndianBytes(paddedTo: 32).hexadecimalString.uppercased(),
            "07775510DB8ED040293D9AC69F7430DBBA7DADE63CE982299E04B79D227873D1"
        )

        let three = G7P256.multiplyGenerator(by: G7BigUInt(3))
        XCTAssertEqual(
            three.x.bigEndianBytes(paddedTo: 32).hexadecimalString.uppercased(),
            "5ECBE4D1A6330A44C8F7EF951D4BF165E6C6B721EFADA985FB41661BC6E7FD6C"
        )
        XCTAssertEqual(
            three.y.bigEndianBytes(paddedTo: 32).hexadecimalString.uppercased(),
            "8734640C4998FF7E374B06CE1A64A2ECD82AB036384FB83D9A79B127A27D5032"
        )
    }

    func testScalarMultiplicationMatchesCryptoKit() {
        for _ in 0 ..< 12 {
            let (scalar, x, y) = randomScalarWithOracle()
            let point = G7P256.multiplyGenerator(by: scalar)
            XCTAssertFalse(point.isInfinity)
            XCTAssertEqual(point.x, x)
            XCTAssertEqual(point.y, y)
            XCTAssertTrue(G7P256.isOnCurve(point))
        }
    }

    func testPointAdditionIsScalarAdditionInTheExponent() {
        for _ in 0 ..< 8 {
            let (a, _, _) = randomScalarWithOracle()
            let (b, _, _) = randomScalarWithOracle()
            let sum = G7BigUInt.addMod(a.modulo(G7P256.order), b.modulo(G7P256.order), G7P256.order)

            let combined = G7P256.add(G7P256.multiplyGenerator(by: a), G7P256.multiplyGenerator(by: b))
            XCTAssertEqual(combined, G7P256.multiplyGenerator(by: sum))
        }
    }

    func testAddingAPointToItselfDoubles() {
        let (a, _, _) = randomScalarWithOracle()
        let point = G7P256.multiplyGenerator(by: a)
        XCTAssertEqual(G7P256.add(point, point), G7P256.multiply(point, by: G7BigUInt(2)))
    }

    func testMultiplyingByOrderYieldsInfinity() {
        XCTAssertTrue(G7P256.multiplyGenerator(by: G7P256.order).isInfinity)
        XCTAssertTrue(G7P256.multiplyGenerator(by: .zero).isInfinity)
    }

    func testAddingInversePointsYieldsInfinity() {
        let (a, _, _) = randomScalarWithOracle()
        let point = G7P256.multiplyGenerator(by: a)
        let negated = G7P256Point(x: point.x, y: G7BigUInt.subMod(.zero, point.y, G7P256.p))
        XCTAssertTrue(G7P256.add(point, negated).isInfinity)
    }

    func testScalarMultiplicationOfAnArbitraryPoint() {
        // (a * b) * G should equal b * (a * G).
        for _ in 0 ..< 5 {
            let (a, _, _) = randomScalarWithOracle()
            let (b, _, _) = randomScalarWithOracle()
            let product = G7BigUInt.mulMod(a, b, G7P256.order)
            XCTAssertEqual(
                G7P256.multiply(G7P256.multiplyGenerator(by: a), by: b),
                G7P256.multiplyGenerator(by: product)
            )
        }
    }

    /// The reduction table is the one part of this file that a transcription
    /// slip could break in a way the curve tests might still pass by luck.
    func testSolinasReductionMatchesLongDivision() {
        for _ in 0 ..< 200 {
            let value = G7BigUInt(bigEndianBytes: Data((0 ..< 64).map { _ in UInt8.random(in: 0 ... 255) }))
            XCTAssertEqual(G7P256.reduce(value), value.modulo(G7P256.p))
        }
        // Boundary values the random draw is unlikely to hit.
        for value in [G7P256.p, G7P256.p - .one, G7P256.p + .one, G7P256.p * G7P256.p] {
            XCTAssertEqual(G7P256.reduce(value), value.modulo(G7P256.p))
        }
    }

    func testUncompressedEncoding() {
        let encoded = G7P256.generator.uncompressedBytes
        XCTAssertEqual(encoded.count, 65)
        XCTAssertEqual(encoded.first, 0x04)
        XCTAssertEqual(
            encoded.dropFirst().prefix(32).hexadecimalString.uppercased(),
            "6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296"
        )
    }
}
