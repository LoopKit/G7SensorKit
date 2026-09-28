//
//  G7PairingView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import G7SensorKit
import SwiftUI

/// Reports the pairing run: that it is working, how long it has been going,
/// and the few things the user can act on.
///
/// Pairing is not one quick handshake. A pairing code does not identify a
/// sensor over the air, so the run has to work through the sensors in range
/// until one accepts it, and spent applicators in a drawer keep advertising
/// for days. The screen has to show that it is still working, or a perfectly
/// healthy run looks stuck.
///
/// It shows no more than that while the run is going. Which sensor is under
/// trial, and what each one answered, are true but not actionable, and they
/// read as claims about the user rather than about a candidate: "not your
/// sensor" on a neighbour's sensor invites a hunt for a wrong code, and a
/// visible "attempt 2 of 3" invites cancelling to get a fresh three, which
/// throws away the run's evidence and restarts its clock. The full narration
/// goes to the device log, which is where anyone who needs it is looking
/// anyway.
struct G7PairingView: View {
    @ObservedObject var viewModel: G7PairingViewModel
    var didEditCode: () -> Void

    @Environment(\.guidanceColors) private var guidanceColors

    private var isPulsing: Bool {
        viewModel.isWorking && viewModel.bluetoothProblem == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // Only the sensor is centred; every line of text starts at the
                // same left edge, which is what makes a screen of changing
                // status readable. Top-aligned too: the text block changes
                // length as the run goes on, and centring made the whole
                // screen jump on every status change.
                VStack(alignment: .leading, spacing: 24) {
                    sensorHero
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    status

                    if viewModel.isWorking {
                        Text(LocalizedString("If iOS asks to pair with the sensor, tap Pair.", comment: "Hint about the system Bluetooth pairing prompt during G7 pairing"))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding()
            }

            buttons
                .padding([.horizontal, .bottom])
        }
        .navigationBarBackButtonHidden(viewModel.isWorking)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    // MARK: - Pieces

    /// The sensor being worked on, pictured as the model it advertised itself
    /// as, inside rings that sweep while the run is live.
    private var sensorHero: some View {
        G7SensorHero(model: viewModel.displayModel, isPulsing: isPulsing, outcome: outcome)
    }

    private var outcome: G7SensorHero.Outcome? {
        switch viewModel.state {
        case .succeeded:
            return .succeeded
        case .failed:
            return .failed
        case .idle, .scanning, .authenticating:
            return nil
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.statusTitle)
                .font(.title2)
                .fontWeight(.semibold)

            if viewModel.isWorking, let startedAt = viewModel.scanStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    Text(String(format: LocalizedString("Looking for %d:%02d", comment: "Elapsed scan time while pairing (1: minutes, 2: seconds)"), elapsed / 60, elapsed % 60))
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            if let problem = viewModel.bluetoothProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .multilineTextAlignment(.leading)
                    .foregroundColor(guidanceColors.critical)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let detail = viewModel.statusDetail {
                Text(detail)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = viewModel.serialFilterNote {
                Label(note, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if case .failed = viewModel.state {
            VStack(spacing: 10) {
                Button(action: { viewModel.retry() }) {
                    Text(LocalizedString("Try Again", comment: "Button title to retry pairing"))
                        .actionButtonStyle(.primary)
                }
                Button(action: didEditCode) {
                    Text(LocalizedString("Change Code", comment: "Button title to go back and edit the pairing code"))
                        .actionButtonStyle(.secondary)
                }
            }
        } else if viewModel.isWorking {
            Button(action: didEditCode) {
                Text(LocalizedString("Cancel", comment: "Button text to cancel G7 setup"))
                    .actionButtonStyle(.secondary)
            }
        }
    }
}
