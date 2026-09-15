//
//  G7PCert.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

enum G7PCertError: Error {
    case invalidLength(Int)
}

/// One round of the sensor's EC-JPAKE exchange, as it appears on the wire:
/// two P-256 points plus a Schnorr proof scalar, each coordinate a 32-byte
/// big-endian value, 160 bytes in all.
///
/// `publicKey` is the value being proven; `proofPoint` is the commitment
/// (`base * randomizer`) the verifier recomputes.
struct G7PCert: Equatable {
    static let byteCount = 160

    let publicKey: G7P256Point
    let proofPoint: G7P256Point
    let proof: G7BigUInt

    init(publicKey: G7P256Point, proofPoint: G7P256Point, proof: G7BigUInt) {
        self.publicKey = publicKey
        self.proofPoint = proofPoint
        self.proof = proof
    }

    init(data: Data) throws {
        guard data.count == G7PCert.byteCount else {
            throw G7PCertError.invalidLength(data.count)
        }
        let bytes = Data(data)
        func coordinate(_ index: Int) -> G7BigUInt {
            let start = bytes.startIndex + index * 32
            return G7BigUInt(bigEndianBytes: bytes[start ..< start + 32])
        }
        publicKey = G7P256Point(x: coordinate(0), y: coordinate(1))
        proofPoint = G7P256Point(x: coordinate(2), y: coordinate(3))
        proof = coordinate(4)
    }

    var encoded: Data {
        var data = Data(capacity: G7PCert.byteCount)
        data.append(publicKey.x.bigEndianBytes(paddedTo: 32))
        data.append(publicKey.y.bigEndianBytes(paddedTo: 32))
        data.append(proofPoint.x.bigEndianBytes(paddedTo: 32))
        data.append(proofPoint.y.bigEndianBytes(paddedTo: 32))
        data.append(proof.bigEndianBytes(paddedTo: 32))
        return data
    }
}
