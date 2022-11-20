//
//  G7SettingsView.swift
//  CGMBLEKitUI
//
//  Created by Pete Schwamb on 9/25/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import SwiftUI
import G7SensorKit
import LoopKitUI

struct G7SettingsView: View {

    private var durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        return formatter
    }()

    @Environment(\.guidanceColors) private var guidanceColors
    @Environment(\.glucoseTintColor) private var glucoseTintColor

    var didFinish: (() -> Void)
    var deleteCGM: (() -> Void)
    @ObservedObject var viewModel: G7SettingsViewModel

    @State private var showingDeletionSheet = false

    init(didFinish: @escaping () -> Void, deleteCGM: @escaping () -> Void, viewModel: G7SettingsViewModel) {
        self.didFinish = didFinish
        self.deleteCGM = deleteCGM
        self.viewModel = viewModel
    }

    private var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()

        formatter.dateStyle = .short
        formatter.timeStyle = .short

        return formatter
    }()

    var body: some View {
        List {
            Section() {
                VStack {
                    headerImage
                    progressBar
                }
            }
            if let activatedAt = viewModel.activatedAt {
                HStack {
                    Text(LocalizedString("Sensor Start", comment: "title for g7 settings row showing sensor start time"))
                    Spacer()
                    Text(timeFormatter.string(from: activatedAt))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text(LocalizedString("Sensor Expires", comment: "title for g7 settings row showing sensor expiration time"))
                    Spacer()
                    Text(timeFormatter.string(from: activatedAt.addingTimeInterval(G7Sensor.lifetime)))
                        .foregroundColor(.secondary)
                }
            }
            if let name = viewModel.sensorName {
                HStack {
                    Text(LocalizedString("Name", comment: "title for g7 settings row showing BLE Name"))
                    Spacer()
                    Text(name)
                        .foregroundColor(.secondary)
                }
            }

            Section("Last Reading") {
                LabeledValueView(label: LocalizedString("Glucose", comment: "Field label"),
                                 value: String(format: "%@ %@", viewModel.lastGlucoseString, viewModel.displayGlucoseUnitObservable.displayGlucoseUnit.shortLocalizedUnitString()))
                LabeledDateView(label: LocalizedString("Time", comment: "Field label"),
                                date: viewModel.lastGlucoseDate,
                                dateFormatter: viewModel.dateFormatter)
                LabeledValueView(label: LocalizedString("Trend", comment: "Field label"),
                                 value: viewModel.lastGlucoseTrendFormatted)
            }


            Section {
                if viewModel.scanning {
                    HStack {
                        Text(LocalizedString("Scanning", comment: "title for g7 settings connection status when scanning"))
                        Spacer()
                        ProgressView()
                    }
                } else {
                    if viewModel.connected {
                        Text(LocalizedString("Connected", comment: "title for g7 settings connection status when connected"))
                    } else {
                        HStack {
                            Text(LocalizedString("Connecting", comment: "title for g7 settings connection status when connecting"))
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                if let lastConnect = viewModel.lastConnect {
                    HStack {
                        Text(LocalizedString("Last Connect", comment: "title for g7 settings row showing sensor last connect time"))
                        Spacer()
                        Text(timeFormatter.string(from: lastConnect))
                    }
                }
            }

            Section () {
                if !self.viewModel.scanning {
                    Button("Scan for new sensor", action: {
                        self.viewModel.scanForNewSensor()
                    })
                }

                deleteCGMButton
            }
        }
        .insetGroupedListStyle()
        .navigationBarItems(trailing: doneButton)
        .navigationBarTitle(LocalizedString("Dexcom G7", comment: "Navigation bar title for G7SettingsView"))
    }

    private var deleteCGMButton: some View {
        Button(action: {
            showingDeletionSheet = true
        }, label: {
            Text(LocalizedString("Delete CGM", comment: "Button label for removing CGM"))
                .foregroundColor(.red)
        }).actionSheet(isPresented: $showingDeletionSheet) {
            ActionSheet(
                title: Text("Are you sure you want to delete this CGM?"),
                buttons: [
                    .destructive(Text("Delete CGM")) {
                        self.deleteCGM()
                    },
                    .cancel(),
                ]
            )
        }
    }

    private var headerImage: some View {
        VStack(alignment: .center) {
            Image(frameworkImage: "g7")
                .resizable()
                .aspectRatio(contentMode: ContentMode.fit)
                .frame(height: 150)
                .padding(.horizontal)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.progressBarState.label)
                    .font(.system(size: 17))
                    .foregroundColor(color(for: viewModel.progressBarState.labelColor))

                Spacer()
                if let duration = viewModel.progressValue {
                    Text(durationFormatter.string(from: duration)!)
                        .foregroundColor(.secondary)
                }
            }
            ProgressView(value: viewModel.progressBarProgress)
                .accentColor(color(for: viewModel.progressBarColorStyle))
        }
    }

    private func color(for colorStyle: ColorStyle) -> Color {
        switch colorStyle {
        case .glucose:
            return glucoseTintColor
        case .warning:
            return guidanceColors.warning
        case .critical:
            return guidanceColors.critical
        case .normal:
            return .primary
        case .dimmed:
            return .secondary
        }
    }


    private var doneButton: some View {
        Button("Done", action: {
            self.didFinish()
        })
    }

}
