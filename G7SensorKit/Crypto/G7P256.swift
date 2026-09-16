//
//  G7P256.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// A point on the NIST P-256 curve in affine coordinates.
struct G7P256Point: Equatable {
    let x: G7BigUInt
    let y: G7BigUInt
    let isInfinity: Bool

    init(x: G7BigUInt, y: G7BigUInt) {
        self.x = x
        self.y = y
        isInfinity = false
    }

    private init() {
        x = .zero
        y = .zero
        isInfinity = true
    }

    static let infinity = G7P256Point()

    /// SEC1 uncompressed encoding: `04 || x || y`, each coordinate padded to
    /// 32 bytes. This is the form the G7 handshake hashes and transmits.
    var uncompressedBytes: Data {
        guard !isInfinity else {
            return Data([0x00])
        }
        return Data([0x04]) + x.bigEndianBytes(paddedTo: 32) + y.bigEndianBytes(paddedTo: 32)
    }
}

/// NIST P-256 (secp256r1) arithmetic.
///
/// Hand-rolled rather than taken from a package: see `G7BigUInt`. Everything
/// here is standard published curve math, and `G7P256Tests` pins it against
/// CryptoKit, which can independently produce `k * G` for any scalar `k`.
enum G7P256 {

    /// Field prime: 2^256 - 2^224 + 2^192 + 2^96 - 1
    static let p = G7BigUInt(bigEndianBytes: Data(hexadecimalString:
        "FFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF")!)

    /// Group order.
    static let order = G7BigUInt(bigEndianBytes: Data(hexadecimalString:
        "FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551")!)

    /// Curve coefficient b. (a is -3 mod p, folded into the doubling formula.)
    static let b = G7BigUInt(bigEndianBytes: Data(hexadecimalString:
        "5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B")!)

    static let generator = G7P256Point(
        x: G7BigUInt(bigEndianBytes: Data(hexadecimalString:
            "6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296")!),
        y: G7BigUInt(bigEndianBytes: Data(hexadecimalString:
            "4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5")!)
    )

    // MARK: - Field arithmetic

    static func fieldAdd(_ lhs: G7BigUInt, _ rhs: G7BigUInt) -> G7BigUInt {
        G7BigUInt.addMod(lhs, rhs, p)
    }

    static func fieldSub(_ lhs: G7BigUInt, _ rhs: G7BigUInt) -> G7BigUInt {
        G7BigUInt.subMod(lhs, rhs, p)
    }

    static func fieldMul(_ lhs: G7BigUInt, _ rhs: G7BigUInt) -> G7BigUInt {
        reduce(lhs * rhs)
    }

    static func fieldSquare(_ value: G7BigUInt) -> G7BigUInt {
        reduce(value * value)
    }

    static func fieldInverse(_ value: G7BigUInt) -> G7BigUInt? {
        value.inverse(modulo: p)
    }

    /// Solinas reduction for the P-256 prime (FIPS 186-4, D.2.3): the prime's
    /// shape lets a 512-bit product be folded into nine 256-bit terms with
    /// only additions and subtractions, avoiding a long division per multiply.
    ///
    /// `G7P256Tests` cross-checks this against generic `modulo(p)` on random
    /// inputs, which is the guard against a transcription slip in the table.
    static func reduce(_ product: G7BigUInt) -> G7BigUInt {
        guard product.bitWidth > 256 else {
            return product < p ? product : product.modulo(p)
        }

        var c = product.limbs
        guard c.count <= 16 else {
            // Only reachable if a caller multiplies unreduced operands.
            return product.modulo(p)
        }
        c.append(contentsOf: [UInt32](repeating: 0, count: 16 - c.count))

        // Each row lists word indices most significant first; nil is a zero word.
        let s1 = compose(c, [7, 6, 5, 4, 3, 2, 1, 0])
        let s2 = compose(c, [15, 14, 13, 12, 11, nil, nil, nil])
        let s3 = compose(c, [nil, 15, 14, 13, 12, nil, nil, nil])
        let s4 = compose(c, [15, 14, nil, nil, nil, 10, 9, 8])
        let s5 = compose(c, [8, 13, 15, 14, 13, 11, 10, 9])
        let s6 = compose(c, [10, 8, nil, nil, nil, 13, 12, 11])
        let s7 = compose(c, [11, 9, nil, nil, 15, 14, 13, 12])
        let s8 = compose(c, [12, nil, 10, 9, 8, 15, 14, 13])
        let s9 = compose(c, [13, nil, 11, 10, 9, nil, 15, 14])

        let positive = s1 + (s2 << 1) + (s3 << 1) + s4 + s5
        let negative = s6 + s7 + s8 + s9

        // Both sides stay under 8p, so repeated subtraction beats a division.
        return G7BigUInt.subMod(smallReduce(positive), smallReduce(negative), p)
    }

    /// Reduces a value known to be a small multiple of `p` above the field.
    private static func smallReduce(_ value: G7BigUInt) -> G7BigUInt {
        var value = value
        var guardCount = 0
        while value >= p {
            value = value - p
            guardCount += 1
            if guardCount > 16 {
                // Unreachable for Solinas inputs; fall back rather than spin.
                return value.modulo(p)
            }
        }
        return value
    }

    /// Builds a 256-bit value from `c` given word indices most significant first.
    private static func compose(_ c: [UInt32], _ indices: [Int?]) -> G7BigUInt {
        G7BigUInt(limbs: indices.reversed().map { index in
            guard let index = index else { return 0 }
            return c[index]
        })
    }

    // MARK: - Point arithmetic

    /// Jacobian projective coordinates: (X, Y, Z) is the affine point
    /// (X/Z², Y/Z³). Used internally so a scalar multiplication needs one
    /// modular inversion at the end instead of one per bit.
    private struct Jacobian {
        var x: G7BigUInt
        var y: G7BigUInt
        var z: G7BigUInt

        var isInfinity: Bool {
            z.isZero
        }

        static let infinity = Jacobian(x: .one, y: .one, z: .zero)
    }

    private static func jacobian(from point: G7P256Point) -> Jacobian {
        point.isInfinity ? .infinity : Jacobian(x: point.x, y: point.y, z: .one)
    }

    private static func affine(from point: Jacobian) -> G7P256Point {
        guard !point.isInfinity, let zInverse = fieldInverse(point.z) else {
            return .infinity
        }
        let zInverse2 = fieldSquare(zInverse)
        let zInverse3 = fieldMul(zInverse2, zInverse)
        return G7P256Point(x: fieldMul(point.x, zInverse2), y: fieldMul(point.y, zInverse3))
    }

    /// Point doubling, using the a = -3 shortcut ("dbl-2001-b").
    private static func double(_ point: Jacobian) -> Jacobian {
        guard !point.isInfinity, !point.y.isZero else {
            return .infinity
        }
        let delta = fieldSquare(point.z)
        let gamma = fieldSquare(point.y)
        let beta = fieldMul(point.x, gamma)
        let alpha = fieldMul(
            G7BigUInt(3),
            fieldMul(fieldSub(point.x, delta), fieldAdd(point.x, delta))
        )
        let eightBeta = fieldMul(G7BigUInt(8), beta)
        let x = fieldSub(fieldSquare(alpha), eightBeta)
        let z = fieldSub(fieldSub(fieldSquare(fieldAdd(point.y, point.z)), gamma), delta)
        let y = fieldSub(
            fieldMul(alpha, fieldSub(fieldMul(G7BigUInt(4), beta), x)),
            fieldMul(G7BigUInt(8), fieldSquare(gamma))
        )
        return Jacobian(x: x, y: y, z: z)
    }

    /// Point addition ("add-2007-bl").
    private static func add(_ lhs: Jacobian, _ rhs: Jacobian) -> Jacobian {
        if lhs.isInfinity {
            return rhs
        }
        if rhs.isInfinity {
            return lhs
        }

        let z1z1 = fieldSquare(lhs.z)
        let z2z2 = fieldSquare(rhs.z)
        let u1 = fieldMul(lhs.x, z2z2)
        let u2 = fieldMul(rhs.x, z1z1)
        let s1 = fieldMul(lhs.y, fieldMul(rhs.z, z2z2))
        let s2 = fieldMul(rhs.y, fieldMul(lhs.z, z1z1))

        if u1 == u2 {
            return s1 == s2 ? double(lhs) : .infinity
        }

        let h = fieldSub(u2, u1)
        let i = fieldSquare(fieldMul(G7BigUInt(2), h))
        let j = fieldMul(h, i)
        let r = fieldMul(G7BigUInt(2), fieldSub(s2, s1))
        let v = fieldMul(u1, i)

        let x = fieldSub(fieldSub(fieldSquare(r), j), fieldMul(G7BigUInt(2), v))
        let y = fieldSub(
            fieldMul(r, fieldSub(v, x)),
            fieldMul(G7BigUInt(2), fieldMul(s1, j))
        )
        let z = fieldMul(
            fieldSub(fieldSub(fieldSquare(fieldAdd(lhs.z, rhs.z)), z1z1), z2z2),
            h
        )
        return Jacobian(x: x, y: y, z: z)
    }

    // MARK: - Public operations

    static func add(_ lhs: G7P256Point, _ rhs: G7P256Point) -> G7P256Point {
        affine(from: add(jacobian(from: lhs), jacobian(from: rhs)))
    }

    /// Left-to-right double-and-add. Not constant time: the values being
    /// multiplied here are ephemeral handshake scalars on a link that is
    /// already physically local, and the alternative is a much larger
    /// implementation to audit.
    static func multiply(_ point: G7P256Point, by scalar: G7BigUInt) -> G7P256Point {
        let scalar = scalar.modulo(order)
        guard !scalar.isZero, !point.isInfinity else {
            return .infinity
        }

        let base = jacobian(from: point)
        var result = Jacobian.infinity
        for index in stride(from: scalar.bitWidth - 1, through: 0, by: -1) {
            result = double(result)
            if scalar.bit(at: index) {
                result = add(result, base)
            }
        }
        return affine(from: result)
    }

    static func multiplyGenerator(by scalar: G7BigUInt) -> G7P256Point {
        multiply(generator, by: scalar)
    }

    /// Whether `point` satisfies y² = x³ - 3x + b over the field.
    static func isOnCurve(_ point: G7P256Point) -> Bool {
        guard !point.isInfinity else {
            return true
        }
        guard point.x < p, point.y < p else {
            return false
        }
        let left = fieldSquare(point.y)
        let right = fieldAdd(
            fieldSub(fieldMul(fieldSquare(point.x), point.x), fieldMul(G7BigUInt(3), point.x)),
            b
        )
        return left == right
    }
}
