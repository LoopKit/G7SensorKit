//
//  G7PairingView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import G7SensorKit
import SwiftUI

/// Shows the pairing run's progress and lets the user retry or go back to
/// the code on failure.
struct G7PairingView: View {
    @ObservedObject var viewModel: G7PairingViewModel
    var didEditCode: () -> Void

    @Environment(\.guidanceColors) private var guidanceColors

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            statusIcon
                .frame(height: 80)

            Text(viewModel.statusTitle)
                .font(.title2)
                .fontWeight(.semibold)

            if let problem = viewModel.bluetoothProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .multilineTextAlignment(.leading)
                    .foregroundColor(guidanceColors.critical)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let detail = viewModel.statusDetail {
                Text(detail)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .scanning(let candidates) = viewModel.state, candidates.isEmpty, let startedAt = viewModel.scanStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    Text(String(format: LocalizedString("Looking for %d:%02d", comment: "Elapsed scan time while pairing (1: minutes, 2: seconds)"), elapsed / 60, elapsed % 60))
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            if viewModel.isWorking {
                Text(LocalizedString("If iOS asks to pair with the sensor, tap Pair.", comment: "Hint about the system Bluetooth pairing prompt during G7 pairing"))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if case .failed = viewModel.state {
                Button(action: { viewModel.retry() }) {
                    Text(LocalizedString("Try Again", comment: "Button title to retry pairing"))
                        .actionButtonStyle(.primary)
                }
                Button(action: didEditCode) {
                    Text(LocalizedString("Change Code", comment: "Button title to go back and edit the pairing code"))
                        .actionButtonStyle(.secondary)
                }
            } else if viewModel.isWorking {
                Button(action: didEditCode) {
                    Text(LocalizedString("Cancel", comment: "Button text to cancel G7 setup"))
                        .actionButtonStyle(.secondary)
                }
            }
        }
        .padding()
        .navigationBarBackButtonHidden(viewModel.isWorking)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.cancel() }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.state {
        case .idle, .scanning, .authenticating:
            ProgressView()
                .scaleEffect(2)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(guidanceColors.acceptable)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(guidanceColors.critical)
        }
    }
}
