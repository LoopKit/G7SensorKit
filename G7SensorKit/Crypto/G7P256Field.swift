//
//  G7P256Field.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// A P-256 field element in Montgomery form, four 64-bit limbs, least significant first. Fixed width
/// and allocation free: `G7BigUInt` was too slow on a watch for the sensor's ~4 s handshake timeout.
struct G7P256Field: Equatable {
    var l0: UInt64
    var l1: UInt64
    var l2: UInt64
    var l3: UInt64

    static let P0: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
    static let P1: UInt64 = 0x0000_0000_FFFF_FFFF
    static let P2: UInt64 = 0x0000_0000_0000_0000
    static let P3: UInt64 = 0xFFFF_FFFF_0000_0001

    static let zero = G7P256Field(l0: 0, l1: 0, l2: 0, l3: 0)

    /// 1 in Montgomery form: 2^256 mod p.
    static let one = G7P256Field(l0: 1, l1: 0xFFFF_FFFF_0000_0000, l2: 0xFFFF_FFFF_FFFF_FFFF, l3: 0x0000_0000_FFFF_FFFE)

    /// 2^512 mod p, for converting into Montgomery form.
    static let rSquared: G7P256Field = {
        let value = (G7BigUInt.one << 512).modulo(G7P256.p)
        return G7P256Field(rawBigEndian: value.bigEndianBytes(paddedTo: 32))
    }()

    private init(rawBigEndian bytes: Data) {
        let b = [UInt8](bytes)
        func limb(_ index: Int) -> UInt64 {
            var value: UInt64 = 0
            for k in 0 ..< 8 {
                value = (value << 8) | UInt64(b[24 - index * 8 + k])
            }
            return value
        }
        self.init(l0: limb(0), l1: limb(1), l2: limb(2), l3: limb(3))
    }

    init(l0: UInt64, l1: UInt64, l2: UInt64, l3: UInt64) {
        self.l0 = l0
        self.l1 = l1
        self.l2 = l2
        self.l3 = l3
    }

    /// Converts a value below p into Montgomery form.
    init(_ value: G7BigUInt) {
        self = G7P256Field.mul(G7P256Field(rawBigEndian: value.bigEndianBytes(paddedTo: 32)), G7P256Field.rSquared)
    }

    var bigUInt: G7BigUInt {
        let raw = G7P256Field.mul(self, G7P256Field(l0: 1, l1: 0, l2: 0, l3: 0))
        var bytes = Data(capacity: 32)
        for limb in [raw.l3, raw.l2, raw.l1, raw.l0] {
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift)))
            }
        }
        return G7BigUInt(bigEndianBytes: bytes)
    }

    var isZero: Bool {
        (l0 | l1 | l2 | l3) == 0
    }

    // MARK: - Limb helpers

    @inline(__always)
    private static func mac(_ a: UInt64, _ b: UInt64, _ c: UInt64, _ carry: inout UInt64) -> UInt64 {
        let (high, low) = a.multipliedFullWidth(by: b)
        let (sum1, overflow1) = low.addingReportingOverflow(c)
        let (sum2, overflow2) = sum1.addingReportingOverflow(carry)
        carry = high &+ (overflow1 ? 1 : 0) &+ (overflow2 ? 1 : 0)
        return sum2
    }

    @inline(__always)
    private static func addCarry(_ a: UInt64, _ b: UInt64) -> (UInt64, UInt64) {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return (sum, overflow ? 1 : 0)
    }

    @inline(__always)
    private static func subBorrow(_ a: UInt64, _ b: UInt64, _ borrow: inout UInt64) -> UInt64 {
        let (d1, o1) = a.subtractingReportingOverflow(b)
        let (d2, o2) = d1.subtractingReportingOverflow(borrow)
        borrow = (o1 || o2) ? 1 : 0
        return d2
    }

    /// Subtracts p once when the value, with an extra carry bit, is at least p.
    @inline(__always)
    fileprivate func subtractingModulusIfNeeded(carry: UInt64) -> G7P256Field {
        var borrow: UInt64 = 0
        let r0 = G7P256Field.subBorrow(l0, G7P256Field.P0, &borrow)
        let r1 = G7P256Field.subBorrow(l1, G7P256Field.P1, &borrow)
        let r2 = G7P256Field.subBorrow(l2, G7P256Field.P2, &borrow)
        let r3 = G7P256Field.subBorrow(l3, G7P256Field.P3, &borrow)
        if carry != 0 || borrow == 0 {
            return G7P256Field(l0: r0, l1: r1, l2: r2, l3: r3)
        }
        return self
    }

    // MARK: - Arithmetic

    static func + (a: G7P256Field, b: G7P256Field) -> G7P256Field {
        var carry: UInt64 = 0
        let s0 = mac(1, a.l0, b.l0, &carry)
        let s1 = mac(1, a.l1, b.l1, &carry)
        let s2 = mac(1, a.l2, b.l2, &carry)
        let s3 = mac(1, a.l3, b.l3, &carry)
        return G7P256Field(l0: s0, l1: s1, l2: s2, l3: s3).subtractingModulusIfNeeded(carry: carry)
    }

    static func - (a: G7P256Field, b: G7P256Field) -> G7P256Field {
        var borrow: UInt64 = 0
        let d0 = subBorrow(a.l0, b.l0, &borrow)
        let d1 = subBorrow(a.l1, b.l1, &borrow)
        let d2 = subBorrow(a.l2, b.l2, &borrow)
        let d3 = subBorrow(a.l3, b.l3, &borrow)
        guard borrow != 0 else {
            return G7P256Field(l0: d0, l1: d1, l2: d2, l3: d3)
        }
        // Went negative: add p back.
        var c: UInt64 = 0
        let r0 = mac(1, P0, d0, &c)
        let r1 = mac(1, P1, d1, &c)
        let r2 = mac(1, P2, d2, &c)
        let r3 = mac(1, P3, d3, &c)
        return G7P256Field(l0: r0, l1: r1, l2: r2, l3: r3)
    }

    static func * (a: G7P256Field, b: G7P256Field) -> G7P256Field {
        mul(a, b)
    }

    var squared: G7P256Field {
        G7P256Field.mul(self, self)
    }

    /// Multiplicative inverse by Fermat: self^(p-2).
    var inverse: G7P256Field {
        // p - 2, most significant limb first.
        let exponent: [UInt64] = [G7P256Field.P3, G7P256Field.P2, G7P256Field.P1, G7P256Field.P0 &- 2]
        var result = G7P256Field.one
        for limb in exponent {
            for bit in stride(from: 63, through: 0, by: -1) {
                result = result.squared
                if (limb >> UInt64(bit)) & 1 == 1 {
                    result = result * self
                }
            }
        }
        return result
    }

    @inline(__always)
    static func mul(_ a: G7P256Field, _ b: G7P256Field) -> G7P256Field {
        var t0: UInt64 = 0, t1: UInt64 = 0, t2: UInt64 = 0, t3: UInt64 = 0, t4: UInt64 = 0, t5: UInt64 = 0
        var c: UInt64 = 0
        var m: UInt64 = 0
        _ = m
        // limb 0
        c = 0
        t0 = mac(a.l0, b.l0, t0, &c)
        t1 = mac(a.l1, b.l0, t1, &c)
        t2 = mac(a.l2, b.l0, t2, &c)
        t3 = mac(a.l3, b.l0, t3, &c)
        (t4, t5) = addCarry(t4, c)
        m = t0
        c = 0
        _ = mac(m, P0, t0, &c)
        t0 = mac(m, P1, t1, &c)
        t1 = mac(m, P2, t2, &c)
        t2 = mac(m, P3, t3, &c)
        (t3, c) = addCarry(t4, c)
        t4 = t5 &+ c
        // limb 1
        c = 0
        t0 = mac(a.l0, b.l1, t0, &c)
        t1 = mac(a.l1, b.l1, t1, &c)
        t2 = mac(a.l2, b.l1, t2, &c)
        t3 = mac(a.l3, b.l1, t3, &c)
        (t4, t5) = addCarry(t4, c)
        m = t0
        c = 0
        _ = mac(m, P0, t0, &c)
        t0 = mac(m, P1, t1, &c)
        t1 = mac(m, P2, t2, &c)
        t2 = mac(m, P3, t3, &c)
        (t3, c) = addCarry(t4, c)
        t4 = t5 &+ c
        // limb 2
        c = 0
        t0 = mac(a.l0, b.l2, t0, &c)
        t1 = mac(a.l1, b.l2, t1, &c)
        t2 = mac(a.l2, b.l2, t2, &c)
        t3 = mac(a.l3, b.l2, t3, &c)
        (t4, t5) = addCarry(t4, c)
        m = t0
        c = 0
        _ = mac(m, P0, t0, &c)
        t0 = mac(m, P1, t1, &c)
        t1 = mac(m, P2, t2, &c)
        t2 = mac(m, P3, t3, &c)
        (t3, c) = addCarry(t4, c)
        t4 = t5 &+ c
        // limb 3
        c = 0
        t0 = mac(a.l0, b.l3, t0, &c)
        t1 = mac(a.l1, b.l3, t1, &c)
        t2 = mac(a.l2, b.l3, t2, &c)
        t3 = mac(a.l3, b.l3, t3, &c)
        (t4, t5) = addCarry(t4, c)
        m = t0
        c = 0
        _ = mac(m, P0, t0, &c)
        t0 = mac(m, P1, t1, &c)
        t1 = mac(m, P2, t2, &c)
        t2 = mac(m, P3, t3, &c)
        (t3, c) = addCarry(t4, c)
        t4 = t5 &+ c
        return G7P256Field(l0: t0, l1: t1, l2: t2, l3: t3).subtractingModulusIfNeeded(carry: t4)
    }
}

/// Jacobian point on P-256 over `G7P256Field`: (X, Y, Z) is the affine point (X/Z², Y/Z³).
struct G7P256Jacobian {
    var x: G7P256Field
    var y: G7P256Field
    var z: G7P256Field

    static let infinity = G7P256Jacobian(x: .one, y: .one, z: .zero)

    var isInfinity: Bool {
        z.isZero
    }

    init(x: G7P256Field, y: G7P256Field, z: G7P256Field) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(_ point: G7P256Point) {
        if point.isInfinity {
            self = .infinity
        } else {
            self.init(x: G7P256Field(point.x), y: G7P256Field(point.y), z: .one)
        }
    }

    var affine: G7P256Point {
        guard !isInfinity else {
            return .infinity
        }
        let zInverse = z.inverse
        let zInverse2 = zInverse.squared
        return G7P256Point(x: (x * zInverse2).bigUInt, y: (y * zInverse2 * zInverse).bigUInt)
    }

    /// Doubling with the a = -3 shortcut ("dbl-2001-b").
    func doubled() -> G7P256Jacobian {
        guard !isInfinity, !y.isZero else {
            return .infinity
        }
        let delta = z.squared
        let gamma = y.squared
        let beta = x * gamma
        let t = (x - delta) * (x + delta)
        let alpha = t + t + t
        let beta2 = beta + beta
        let beta4 = beta2 + beta2
        let beta8 = beta4 + beta4
        let newX = alpha.squared - beta8
        let yz = y + z
        let newZ = yz.squared - gamma - delta
        let gamma2 = gamma.squared
        let gamma2x2 = gamma2 + gamma2
        let gamma2x4 = gamma2x2 + gamma2x2
        let gamma2x8 = gamma2x4 + gamma2x4
        let newY = alpha * (beta4 - newX) - gamma2x8
        return G7P256Jacobian(x: newX, y: newY, z: newZ)
    }

    /// Addition ("add-2007-bl").
    static func + (lhs: G7P256Jacobian, rhs: G7P256Jacobian) -> G7P256Jacobian {
        if lhs.isInfinity {
            return rhs
        }
        if rhs.isInfinity {
            return lhs
        }
        let z1z1 = lhs.z.squared
        let z2z2 = rhs.z.squared
        let u1 = lhs.x * z2z2
        let u2 = rhs.x * z1z1
        let s1 = lhs.y * rhs.z * z2z2
        let s2 = rhs.y * lhs.z * z1z1
        if u1 == u2 {
            return s1 == s2 ? lhs.doubled() : .infinity
        }
        let h = u2 - u1
        let h2 = h + h
        let i = h2.squared
        let j = h * i
        let sDiff = s2 - s1
        let r = sDiff + sDiff
        let v = u1 * i
        let newX = r.squared - j - v - v
        let s1j = s1 * j
        let newY = r * (v - newX) - s1j - s1j
        let zSum = lhs.z + rhs.z
        let newZ = (zSum.squared - z1z1 - z2z2) * h
        return G7P256Jacobian(x: newX, y: newY, z: newZ)
    }

    /// Fixed 4-bit window: 252 doublings and at most 64 additions after a 14-addition table. Not
    /// constant time, like the code it replaces: the scalars are ephemeral, on a physically local link.
    func multiplied(byBigEndian scalar: Data) -> G7P256Jacobian {
        var table = [G7P256Jacobian](repeating: .infinity, count: 16)
        table[1] = self
        for k in 2 ..< 16 {
            table[k] = table[k - 1] + self
        }
        var result = G7P256Jacobian.infinity
        var started = false
        for byte in scalar {
            for nibble in [Int(byte >> 4), Int(byte & 0x0F)] {
                if started {
                    result = result.doubled().doubled().doubled().doubled()
                }
                if nibble != 0 {
                    result = result + table[nibble]
                    started = true
                }
            }
        }
        return result
    }
}
