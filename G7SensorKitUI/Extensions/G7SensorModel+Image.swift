//
//  G7SensorModel+Image.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import G7SensorKit
import SwiftUI

extension G7SensorModel {
    /// The product image for this model in the framework's asset catalog.
    var imageName: String {
        switch self {
        case .g7: return "g7"
        case .onePlus: return "oneplus"
        case .stelo: return "stelo"
        }
    }

    var image: Image {
        Image(frameworkImage: imageName)
    }

    var uiImage: UIImage? {
        UIImage(named: imageName, in: FrameworkBundle.main, compatibleWith: nil)
    }
}
