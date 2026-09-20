//
//  G7BigUIntTests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import G7SensorKit

class G7BigUIntTests: XCTestCase {

    private func random(byteCount: Int) -> G7BigUInt {
        G7BigUInt(bigEndianBytes: Data((0 ..< byteCount).map { _ in UInt8.random(in: 0 ... 255) }))
    }

    func testBigEndianRoundTrip() {
        let hex = "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF"
        let value = G7BigUInt(bigEndianBytes: Data(hexadecimalString: hex)!)
        XCTAssertEqual(value.bigEndianBytes(paddedTo: 32).hexadecimalString.uppercased(), hex)
    }

    func testLeadingZeroesArePadded() {
        let value = G7BigUInt(258)
        XCTAssertEqual(value.bigEndianBytes(paddedTo: 4).hexadecimalString, "00000102")
    }

    func testZero() {
        XCTAssertTrue(G7BigUInt.zero.isZero)
        XCTAssertTrue(G7BigUInt.zero.isEven)
        XCTAssertEqual(G7BigUInt.zero.bitWidth, 0)
        XCTAssertEqual(G7BigUInt.zero.bigEndianBytes(paddedTo: 4).hexadecimalString, "00000000")
        XCTAssertEqual(G7BigUInt(bigEndianBytes: Data([0, 0, 0])), .zero)
    }

    func testAdditionCarriesAcrossLimbs() {
        let max32 = G7BigUInt(bigEndianBytes: Data(hexadecimalString: "FFFFFFFF")!)
        XCTAssertEqual((max32 + .one).bigEndianBytes(paddedTo: 5).hexadecimalString, "0100000000")
    }

    func testSubtractionBorrowsAcrossLimbs() {
        let value = G7BigUInt(bigEndianBytes: Data(hexadecimalString: "0100000000")!)
        XCTAssertEqual((value - .one).bigEndianBytes(paddedTo: 4).hexadecimalString, "ffffffff")
    }

    func testShifts() {
        for _ in 0 ..< 50 {
            let value = random(byteCount: 24)
            for shift in [1, 7, 32, 33, 64, 100] {
                let shifted = value << shift
                XCTAssertEqual(shifted >> shift, value, "round trip failed for shift \(shift)")
                // Shifting left by n is multiplication by 2^n.
                var expected = value
                for _ in 0 ..< shift {
                    expected = expected + expected
                }
                XCTAssertEqual(shifted, expected, "shift \(shift) disagrees with repeated doubling")
            }
        }
    }

    func testMultiplicationAgainstRepeatedAddition() {
        for _ in 0 ..< 30 {
            let a = random(byteCount: 8)
            let multiplier = UInt32.random(in: 0 ... 200)
            var expected = G7BigUInt.zero
            for _ in 0 ..< multiplier {
                expected = expected + a
            }
            XCTAssertEqual(a * G7BigUInt(multiplier), expected)
        }
    }

    func testDivisionInvariant() {
        for _ in 0 ..< 40 {
            let dividend = random(byteCount: 64)
            let divisor = random(byteCount: 32)
            guard !divisor.isZero else { continue }
            let (quotient, remainder) = dividend.quotientAndRemainder(dividingBy: divisor)
            XCTAssertTrue(remainder < divisor)
            XCTAssertEqual(quotient * divisor + remainder, dividend)
        }
    }

    func testModularInverse() {
        for modulus in [G7P256.p, G7P256.order] {
            for _ in 0 ..< 20 {
                let value = random(byteCount: 32).modulo(modulus)
                guard !value.isZero else { continue }
                guard let inverse = value.inverse(modulo: modulus) else {
                    XCTFail("no inverse for \(value)")
                    continue
                }
                XCTAssertEqual(G7BigUInt.mulMod(value, inverse, modulus), .one)
            }
        }
    }

    func testAddModAndSubMod() {
        let modulus = G7P256.order
        for _ in 0 ..< 40 {
            let a = random(byteCount: 32).modulo(modulus)
            let b = random(byteCount: 32).modulo(modulus)
            XCTAssertEqual(G7BigUInt.addMod(a, b, modulus), (a + b).modulo(modulus))
            XCTAssertEqual(G7BigUInt.addMod(G7BigUInt.subMod(a, b, modulus), b, modulus), a)
        }
    }
}
