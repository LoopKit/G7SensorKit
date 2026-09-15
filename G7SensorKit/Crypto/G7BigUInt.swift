//
//  G7BigUInt.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// Minimal arbitrary-precision unsigned integer, sized for the 256- and
/// 512-bit values P-256 curve arithmetic needs.
///
/// Little-endian 32-bit limbs: `limbs[0]` is least significant, and the
/// representation is always normalized, so zero is the empty array and
/// `limbs.last` is never 0.
///
/// This exists so the G7 pairing handshake can do elliptic-curve arithmetic
/// without a third-party big-integer package. CryptoKit exposes no primitive
/// point addition or arbitrary-scalar multiplication, and a Loop plugin that
/// links SwiftPM products needs the host app to embed them or it fails to
/// load at runtime.
struct G7BigUInt: Equatable, Comparable, CustomStringConvertible {

    private(set) var limbs: [UInt32]

    static let zero = G7BigUInt()
    static let one = G7BigUInt(1)

    // MARK: - Creation

    init() {
        limbs = []
    }

    init(_ value: UInt32) {
        limbs = value == 0 ? [] : [value]
    }

    /// Takes limbs least-significant first and normalizes them.
    init(limbs: [UInt32]) {
        var limbs = limbs
        while limbs.last == 0 {
            limbs.removeLast()
        }
        self.limbs = limbs
    }

    /// Interprets `data` as a big-endian unsigned integer.
    init(bigEndianBytes data: Data) {
        var limbs = [UInt32]()
        limbs.reserveCapacity((data.count + 3) / 4)
        var accumulator: UInt32 = 0
        var shift: UInt32 = 0
        for byte in data.reversed() {
            accumulator |= UInt32(byte) << shift
            shift += 8
            if shift == 32 {
                limbs.append(accumulator)
                accumulator = 0
                shift = 0
            }
        }
        if shift > 0 {
            limbs.append(accumulator)
        }
        self.init(limbs: limbs)
    }

    /// Big-endian bytes, left-zero-padded to `length`. Truncates from the
    /// most significant end if the value does not fit, which never happens
    /// for values already reduced modulo a 256-bit modulus.
    func bigEndianBytes(paddedTo length: Int) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(limbs.count * 4)
        for limb in limbs {
            bytes.append(UInt8(truncatingIfNeeded: limb))
            bytes.append(UInt8(truncatingIfNeeded: limb >> 8))
            bytes.append(UInt8(truncatingIfNeeded: limb >> 16))
            bytes.append(UInt8(truncatingIfNeeded: limb >> 24))
        }
        while bytes.last == 0 {
            bytes.removeLast()
        }
        bytes.reverse()

        if bytes.count >= length {
            return Data(bytes.suffix(length))
        }
        return Data(repeating: 0, count: length - bytes.count) + Data(bytes)
    }

    // MARK: - Inspection

    var isZero: Bool {
        limbs.isEmpty
    }

    var isEven: Bool {
        limbs.first.map { $0 & 1 == 0 } ?? true
    }

    /// Position of the most significant set bit, plus one. Zero for zero.
    var bitWidth: Int {
        guard let top = limbs.last else {
            return 0
        }
        return limbs.count * 32 - Int(top.leadingZeroBitCount)
    }

    func bit(at index: Int) -> Bool {
        let limbIndex = index / 32
        guard limbIndex < limbs.count else {
            return false
        }
        return limbs[limbIndex] >> UInt32(index % 32) & 1 == 1
    }

    var description: String {
        isZero ? "0x0" : "0x" + bigEndianBytes(paddedTo: (bitWidth + 7) / 8).hexadecimalString
    }

    // MARK: - Comparison

    static func < (lhs: G7BigUInt, rhs: G7BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }

    // MARK: - Arithmetic

    static func + (lhs: G7BigUInt, rhs: G7BigUInt) -> G7BigUInt {
        var result = [UInt32]()
        result.reserveCapacity(max(lhs.limbs.count, rhs.limbs.count) + 1)
        var carry: UInt64 = 0
        for index in 0 ..< max(lhs.limbs.count, rhs.limbs.count) {
            let sum = UInt64(index < lhs.limbs.count ? lhs.limbs[index] : 0)
                + UInt64(index < rhs.limbs.count ? rhs.limbs[index] : 0)
                + carry
            result.append(UInt32(truncatingIfNeeded: sum))
            carry = sum >> 32
        }
        if carry > 0 {
            result.append(UInt32(carry))
        }
        return G7BigUInt(limbs: result)
    }

    /// Truncating subtraction. `lhs` must be at least `rhs`; the callers here
    /// all compare first, and a borrow out of the top limb would silently
    /// produce a wrapped value.
    static func - (lhs: G7BigUInt, rhs: G7BigUInt) -> G7BigUInt {
        precondition(lhs >= rhs, "G7BigUInt subtraction would underflow")
        var result = [UInt32]()
        result.reserveCapacity(lhs.limbs.count)
        var borrow: Int64 = 0
        for index in 0 ..< lhs.limbs.count {
            let difference = Int64(lhs.limbs[index])
                - Int64(index < rhs.limbs.count ? rhs.limbs[index] : 0)
                - borrow
            if difference < 0 {
                result.append(UInt32(truncatingIfNeeded: difference + 0x1_0000_0000))
                borrow = 1
            } else {
                result.append(UInt32(difference))
                borrow = 0
            }
        }
        return G7BigUInt(limbs: result)
    }

    static func * (lhs: G7BigUInt, rhs: G7BigUInt) -> G7BigUInt {
        guard !lhs.isZero, !rhs.isZero else {
            return .zero
        }
        var result = [UInt32](repeating: 0, count: lhs.limbs.count + rhs.limbs.count)
        for i in 0 ..< lhs.limbs.count {
            var carry: UInt64 = 0
            let a = UInt64(lhs.limbs[i])
            for j in 0 ..< rhs.limbs.count {
                let product = a * UInt64(rhs.limbs[j]) + UInt64(result[i + j]) + carry
                result[i + j] = UInt32(truncatingIfNeeded: product)
                carry = product >> 32
            }
            var index = i + rhs.limbs.count
            while carry > 0 {
                let sum = UInt64(result[index]) + carry
                result[index] = UInt32(truncatingIfNeeded: sum)
                carry = sum >> 32
                index += 1
            }
        }
        return G7BigUInt(limbs: result)
    }

    static func << (lhs: G7BigUInt, shift: Int) -> G7BigUInt {
        guard !lhs.isZero, shift > 0 else {
            return lhs
        }
        let limbShift = shift / 32
        let bitShift = UInt32(shift % 32)
        var result = [UInt32](repeating: 0, count: limbShift)
        var carry: UInt32 = 0
        for limb in lhs.limbs {
            result.append(bitShift == 0 ? limb : (limb << bitShift) | carry)
            carry = bitShift == 0 ? 0 : limb >> (32 - bitShift)
        }
        if carry > 0 {
            result.append(carry)
        }
        return G7BigUInt(limbs: result)
    }

    static func >> (lhs: G7BigUInt, shift: Int) -> G7BigUInt {
        guard !lhs.isZero, shift > 0 else {
            return lhs
        }
        let limbShift = shift / 32
        guard limbShift < lhs.limbs.count else {
            return .zero
        }
        let bitShift = UInt32(shift % 32)
        var result = Array(lhs.limbs[limbShift...])
        if bitShift > 0 {
            for index in 0 ..< result.count {
                let high = index + 1 < result.count ? result[index + 1] << (32 - bitShift) : 0
                result[index] = (result[index] >> bitShift) | high
            }
        }
        return G7BigUInt(limbs: result)
    }

    // MARK: - Division

    /// Binary long division. Chosen over Knuth D for auditability: the values
    /// here are at most 512 bits and every hot-path reduction goes through
    /// `G7P256`'s Solinas reduction instead.
    func quotientAndRemainder(dividingBy divisor: G7BigUInt) -> (quotient: G7BigUInt, remainder: G7BigUInt) {
        precondition(!divisor.isZero, "G7BigUInt division by zero")
        if self < divisor {
            return (.zero, self)
        }

        var quotient = [UInt32](repeating: 0, count: limbs.count)
        var remainder = G7BigUInt.zero
        for index in stride(from: bitWidth - 1, through: 0, by: -1) {
            remainder = remainder << 1
            if bit(at: index) {
                remainder = remainder + .one
            }
            if remainder >= divisor {
                remainder = remainder - divisor
                quotient[index / 32] |= 1 << UInt32(index % 32)
            }
        }
        return (G7BigUInt(limbs: quotient), remainder)
    }

    func modulo(_ modulus: G7BigUInt) -> G7BigUInt {
        if self < modulus {
            return self
        }
        return quotientAndRemainder(dividingBy: modulus).remainder
    }

    // MARK: - Modular arithmetic

    /// Both operands must already be reduced modulo `modulus`.
    static func addMod(_ lhs: G7BigUInt, _ rhs: G7BigUInt, _ modulus: G7BigUInt) -> G7BigUInt {
        let sum = lhs + rhs
        return sum >= modulus ? sum - modulus : sum
    }

    /// Both operands must already be reduced modulo `modulus`.
    static func subMod(_ lhs: G7BigUInt, _ rhs: G7BigUInt, _ modulus: G7BigUInt) -> G7BigUInt {
        lhs >= rhs ? lhs - rhs : modulus - (rhs - lhs)
    }

    static func mulMod(_ lhs: G7BigUInt, _ rhs: G7BigUInt, _ modulus: G7BigUInt) -> G7BigUInt {
        (lhs * rhs).modulo(modulus)
    }

    /// Modular inverse by the binary extended Euclidean algorithm, which
    /// requires an odd modulus. Both P-256 moduli (the field prime and the
    /// group order) are odd primes. Returns nil when no inverse exists.
    func inverse(modulo modulus: G7BigUInt) -> G7BigUInt? {
        precondition(!modulus.isEven, "G7BigUInt modular inverse requires an odd modulus")
        var u = modulo(modulus)
        guard !u.isZero else {
            return nil
        }
        var v = modulus
        var x1 = G7BigUInt.one
        var x2 = G7BigUInt.zero

        // Halving x under an odd modulus: if x is odd, adding the modulus
        // makes it even without changing the residue.
        func halve(_ x: G7BigUInt) -> G7BigUInt {
            x.isEven ? (x >> 1) : ((x + modulus) >> 1)
        }

        while u != .one, v != .one {
            while u.isEven {
                u = u >> 1
                x1 = halve(x1)
            }
            while v.isEven {
                v = v >> 1
                x2 = halve(x2)
            }
            if u.isZero || v.isZero {
                return nil
            }
            if u >= v {
                u = u - v
                x1 = G7BigUInt.subMod(x1, x2, modulus)
            } else {
                v = v - u
                x2 = G7BigUInt.subMod(x2, x1, modulus)
            }
        }
        return (u == .one ? x1 : x2).modulo(modulus)
    }
}
