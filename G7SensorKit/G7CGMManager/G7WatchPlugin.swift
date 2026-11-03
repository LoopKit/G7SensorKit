//
//  G7WatchPlugin.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit

extension G7CGMManager: DirectReadCGMManager {
    public var directReadStatusNote: String? {
        G7WatchDirectRead.needsCodeNote(for: needsCodeForSensor) ?? G7WatchDirectRead.searchingNote(isSearchingForSensor)
    }
}

/// The watch loads this kit at run time, as the phone loads its plugins: this is the bundle's principal class.
@objc(G7SensorWatchPlugin)
final class G7SensorWatchPlugin: NSObject, CGMManagerPlugin {
    var cgmManagerType: CGMManager.Type? { G7CGMManager.self }
}
