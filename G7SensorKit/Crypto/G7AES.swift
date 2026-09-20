//
//  G7AES.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CommonCrypto
import Foundation

enum G7AESError: Error {
    case invalidKeyLength(Int)
    case invalidInputLength(Int)
    case cryptoFailure(CCCryptorStatus)
}

enum G7AES {

    /// Dexcom's challenge transform: the 8-byte challenge is repeated to fill
    /// one AES block, encrypted under the session key in ECB mode, and the
    /// first 8 bytes of the result are the answer. Both sides compute it, and
    /// a mismatch means the two ends do not share a key.
    static func encryptChallenge(_ challenge: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else {
            throw G7AESError.invalidKeyLength(key.count)
        }
        guard challenge.count == 8 else {
            throw G7AESError.invalidInputLength(challenge.count)
        }

        let block = challenge + challenge
        let outputCount = block.count
        var output = Data(count: outputCount)
        var bytesWritten = 0

        let status = output.withUnsafeMutableBytes { outputBuffer in
            block.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        keyBuffer.baseAddress, key.count,
                        nil,
                        inputBuffer.baseAddress, block.count,
                        outputBuffer.baseAddress, outputCount,
                        &bytesWritten
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw G7AESError.cryptoFailure(status)
        }
        return output.prefix(8)
    }
}
