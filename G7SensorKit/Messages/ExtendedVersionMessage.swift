//
//  ExtendedVersion.swift
//  G7SensorKit
//
//  Created by Pete Schwamb on 12/31/25.
//  Copyright © 2025 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit

public struct ExtendedVersionMessage: SensorMessage, Equatable {
    public let sessionLength: TimeInterval
    public let warmupLength: TimeInterval
    public let algorithmVersion: UInt32
    public let hardwareVersion: UInt8
    public let maxLifetimeDays: UInt16

    public let data: Data

    init?(data: Data) {
        self.data = data

        // 52 00 c0d70d00 5406 00020404 ff 0c00

        guard data.starts(with: .extendedVersionTx) else {
            return nil
        }

        guard data.count >= 15 else {
            return nil
        }

        sessionLength = TimeInterval(data[2..<6].to(UInt32.self))
        warmupLength = TimeInterval(data[6..<8].to(UInt16.self))
        algorithmVersion = data[8..<12].to(UInt32.self)
        hardwareVersion = data[12]
        maxLifetimeDays = data[13..<15].to(UInt16.self)
    }
}

extension ExtendedVersionMessage: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "ExtendedVersionMessage(sessionLength:\(sessionLength), warmupLength:\(warmupLength) algorithmVersion:\(algorithmVersion) hardwareVersion:\(hardwareVersion) maxLifetimeDays:\(maxLifetimeDays))"
    }
}
