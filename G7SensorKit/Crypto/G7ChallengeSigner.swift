//
//  G7ChallengeSigner.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CryptoKit
import Foundation

enum G7ChallengeSignerError: Error {
    case challengeTooShort(Int)
}

/// Answers the sensor's key challenge, the last proof of identity before it
/// agrees to bond.
///
/// The sensor sends a 0x0C acknowledgement carrying 16 bytes to sign; we
/// return an ECDSA-P256 signature over exactly those bytes, made with the
/// fixed key whose certificate we uploaded moments earlier.
enum G7ChallengeSigner {

    private static let privateKey: P256.Signing.PrivateKey = {
        // The key material is a compile-time constant, so a failure here is a
        // build mistake rather than a runtime condition.
        // swiftlint:disable:next force_try
        try! P256.Signing.PrivateKey(rawRepresentation: G7DexcomCredentials.challengePrivateKey)
    }()

    static var publicKey: Data {
        G7DexcomCredentials.challengePublicKey
    }

    /// Signs the 16 payload bytes of the sensor's `0C` acknowledgement,
    /// returning the 64-byte raw (r ‖ s) signature.
    static func sign(challengeAcknowledgement: Data) throws -> Data {
        guard challengeAcknowledgement.count >= 18 else {
            throw G7ChallengeSignerError.challengeTooShort(challengeAcknowledgement.count)
        }
        let start = challengeAcknowledgement.startIndex + 2
        let payload = challengeAcknowledgement[start ..< start + 16]
        return try privateKey.signature(for: payload).rawRepresentation
    }
}
