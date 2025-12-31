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
    public let sessionLength: UInt32
    public let warmupLength: UInt16
    public let algorithmVersion: UInt32
    public let hardwareVersion: UInt8
    public let maxLifetimeDays: UInt16
    public let data: Data

    init?(data: Data) {
        self.data = data

        guard data.starts(with: .extendedVersionRx) else {
            return nil
        }

        guard data.count >= 14 else {
            return nil
        }

        sessionLength = data[1..<5].toInt()
        warmupLength = data[5..<7].toInt()
        algorithmVersion = data[7..<11].toInt()
        hardwareVersion = data[11]
        maxLifetimeDays = data[12..<16].toInt()
    }
}

extension ExtendedVersionMessage: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "ExtendedVersionMessage(sessionLength:\(sessionLength), warmupLength:\(warmupLength) algorithmVersion:\(algorithmVersion) hardwareVersion:\(hardwareVersion) maxLifetimeDays:\(maxLifetimeDays))"
    }
}
