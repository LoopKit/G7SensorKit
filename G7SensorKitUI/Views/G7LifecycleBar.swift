//
//  G7LifecycleBar.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI

/// The session progress bar: the pump plugins' 8pt bar, drawn with capsules.
///
/// LoopKitUI's ProgressView rounds two rectangles with a corner radius of
/// half the bar height, and a radius clamps to half the shape's smaller
/// side; a fill a few points wide, as at the start of a session, comes out
/// as a square nub. Capsules always round fully, and the fill is never
/// narrower than the bar is tall, so it reads as a dot growing into a pill.
struct G7LifecycleBar: View {
    var progress: Double
    var color: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(color)
                    .frame(width: max(height, geometry.size.width * CGFloat(min(max(progress, 0), 1))))
            }
        }
        .frame(height: height)
    }
}
