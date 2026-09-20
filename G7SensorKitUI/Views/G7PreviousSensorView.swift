//
//  G7PreviousSensorView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import G7SensorKit
import LoopKitUI
import SwiftUI

/// The sensor before the current one: what it was, when it ran, how it ended.
struct G7PreviousSensorView: View {
    let record: G7SensorRecord

    @Environment(\.guidanceColors) private var guidanceColors

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter
    }()

    var body: some View {
        List {
            if let failureMessage = record.failureMessage {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(guidanceColors.critical)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(LocalizedString("Sensor Failed", comment: "Title of the failure notice on the previous sensor page"))
                                .font(.headline)
                            Text(failureMessage)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            if let failedAt = record.failedAt {
                                Text(dateFormatter.string(from: failedAt))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section(header: Text(LocalizedString("Sensor", comment: "Section header for sensor details"))) {
                LabeledValueView(
                    label: LocalizedString("Model", comment: "Row label for the sensor model"),
                    value: record.model?.displayName(sessionLength: record.sessionLength) ?? record.sensorID
                )
                LabeledValueView(
                    label: LocalizedString("Name", comment: "title for g7 settings row showing BLE Name"),
                    value: record.sensorID
                )
                if let serialNumber = record.serialNumber {
                    LabeledValueView(
                        label: LocalizedString("Serial Number", comment: "title for g7 settings row showing the sensor serial number"),
                        value: serialNumber
                    )
                }
                if let pairingCode = record.pairingCode {
                    LabeledValueView(
                        label: LocalizedString("Pairing Code", comment: "Row label for the sensor's pairing code"),
                        value: pairingCode
                    )
                }
                if let firmwareVersion = record.firmwareVersion {
                    LabeledValueView(
                        label: LocalizedString("Firmware", comment: "title for g7 settings row showing the sensor firmware version"),
                        value: firmwareVersion
                    )
                }
                if let sessionLength = record.sessionLength {
                    LabeledValueView(
                        label: LocalizedString("Session Length", comment: "Row label for the sensor's session length"),
                        value: durationFormatter.string(from: sessionLength) ?? ""
                    )
                }
            }

            Section(header: Text(LocalizedString("Session", comment: "Section header for the previous sensor's session dates"))) {
                if let pairedAt = record.pairedAt {
                    LabeledValueView(
                        label: LocalizedString("Paired", comment: "Row label for when the sensor was paired"),
                        value: dateFormatter.string(from: pairedAt)
                    )
                }
                if let activatedAt = record.activatedAt {
                    LabeledValueView(
                        label: LocalizedString("Sensor Start", comment: "title for g7 settings row showing sensor start time"),
                        value: dateFormatter.string(from: activatedAt)
                    )
                }
                LabeledValueView(
                    label: endLabel,
                    value: dateFormatter.string(from: record.endedAt)
                )
                if let activatedAt = record.activatedAt {
                    LabeledValueView(
                        label: LocalizedString("Worn For", comment: "Row label for how long the previous sensor was in use"),
                        value: durationFormatter.string(from: record.endedAt.timeIntervalSince(activatedAt)) ?? ""
                    )
                }
            }
        }
        .insetGroupedListStyle()
        .navigationBarTitle(Text(LocalizedString("Previous Sensor", comment: "Navigation title of the previous sensor page")), displayMode: .inline)
    }

    private var endLabel: String {
        switch record.endReason {
        case .replaced:
            return LocalizedString("Replaced", comment: "Row label for when the previous sensor was replaced")
        case .deleted:
            return LocalizedString("Removed", comment: "Row label for when the previous sensor's CGM was deleted")
        }
    }
}
