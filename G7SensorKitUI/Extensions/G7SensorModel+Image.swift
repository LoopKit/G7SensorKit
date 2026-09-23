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

/// The sensor, pictured as the model it announced itself as, with the run's
/// verdict on it. Shared by the pairing screen and the success screen that
/// follows, so one pairing keeps one face from the search to the finish.
///
/// The product shots are a near-white adhesive patch on a transparent canvas,
/// so nothing is tinted behind them while the run is still going: a fill there
/// reads as a smudge over the patch rather than as a halo behind it. The
/// verdict colours earn their fill by being worth the noise.
struct G7SensorHero: View {
    enum Outcome {
        case succeeded
        case failed
    }

    let model: G7SensorModel
    /// Whether to sweep rings outward behind the sensor, for a run that is
    /// still looking.
    var isPulsing = false
    var outcome: Outcome?

    @Environment(\.guidanceColors) private var guidanceColors

    var body: some View {
        ZStack {
            if isPulsing {
                ForEach(0 ..< 2, id: \.self) { ring in
                    PulseRing(delay: Double(ring) * G7SensorHero.pulseDuration / 2)
                }
            }

            if let color = outcomeColor {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 176, height: 176)
            }

            model.image
                .resizable()
                .scaledToFit()
                .frame(height: 118)

            if let outcome = outcome, let color = outcomeColor {
                Image(systemName: outcome == .succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundColor(color)
                    .background(Circle().fill(Color(.systemBackground)).padding(5))
                    .offset(x: 54, y: 54)
            }
        }
        .frame(width: 190, height: 190)
    }

    /// Green for a pairing that worked, and it is a literal: hosts map
    /// `guidanceColors.acceptable` to `.primary` (Trio does), which is the
    /// right call for a reading that is merely in range but leaves a success
    /// mark black. Failure still takes the host's critical colour, which is
    /// red everywhere.
    private var outcomeColor: Color? {
        switch outcome {
        case .succeeded?:
            return .green
        case .failed?:
            return guidanceColors.critical
        case nil:
            return nil
        }
    }

    /// One outward sweep of a ring.
    private static let pulseDuration: TimeInterval = 1.8

    /// A ring that sweeps outward and fades, forever. Its own view with its
    /// own state, because the animation has to start when the ring appears:
    /// the run is already under way by then, so a flag the screen set on its
    /// own appearance would have flipped before there was anything to animate.
    private struct PulseRing: View {
        let delay: TimeInterval

        @State private var expanded = false

        var body: some View {
            Circle()
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 3)
                .frame(width: 168, height: 168)
                .scaleEffect(expanded ? 1.12 : 0.88)
                .opacity(expanded ? 0 : 0.9)
                .onAppear {
                    withAnimation(
                        .easeOut(duration: G7SensorHero.pulseDuration)
                            .repeatForever(autoreverses: false)
                            .delay(delay)
                    ) {
                        expanded = true
                    }
                }
        }
    }
}
