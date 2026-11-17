//
//  G7SensorIdentityRows.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import SwiftUI
import LoopKitUI

/// Model, name, serial number and pairing code, the last two copyable.
/// The caller supplies the `Section`, so notices can sit above these rows.
struct G7SensorIdentityRows: View {
    let model: String
    let name: String?
    let serialNumber: String?
    let pairingCode: String?

    @State private var copiedValue: String?

    var body: some View {
        LabeledValueView(
            label: LocalizedString("Model", comment: "Row label for the sensor model"),
            value: model
        )
        if let name = name {
            LabeledValueView(
                label: LocalizedString("Name", comment: "title for g7 settings row showing BLE Name"),
                value: name
            )
        }
        if let serialNumber = serialNumber {
            copyableRow(
                label: LocalizedString("Serial Number", comment: "title for g7 settings row showing the sensor serial number"),
                value: serialNumber
            )
        }
        if let pairingCode = pairingCode {
            copyableRow(
                label: LocalizedString("Pairing Code", comment: "Row label for the sensor's pairing code"),
                value: pairingCode
            )
        }
    }

    /// A value row that copies on tap (and offers Copy in its context menu),
    /// confirming briefly in place.
    private func copyableRow(label: String, value: String) -> some View {
        Button(action: {
            UIPasteboard.general.string = value
            withAnimation { copiedValue = value }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation {
                    if copiedValue == value {
                        copiedValue = nil
                    }
                }
            }
        }) {
            HStack {
                Text(label)
                    .foregroundColor(.primary)
                Spacer()
                if copiedValue == value {
                    Text(LocalizedString("Copied", comment: "Confirmation shown briefly after copying a settings value"))
                        .foregroundColor(.secondary)
                } else {
                    Text(value)
                        .foregroundColor(.secondary)
                    Image(systemName: "doc.on.doc")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .contextMenu {
            Button(action: { UIPasteboard.general.string = value }) {
                Label(LocalizedString("Copy", comment: "Context menu action to copy a settings value"), systemImage: "doc.on.doc")
            }
        }
    }
}
