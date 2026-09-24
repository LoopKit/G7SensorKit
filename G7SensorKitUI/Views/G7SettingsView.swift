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
    
    private var sessionLengthFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter
    }()
    
    @Environment(\.guidanceColors) private var guidanceColors
    @Environment(\.glucoseTintColor) private var glucoseTintColor

    var didFinish: (() -> Void)
    var deleteCGM: (() -> Void)
    /// Pair a sensor that still has to be applied (replacement, or first
    /// direct sensor after eavesdropping ends).
    var pairNewSensor: (() -> Void)
    /// Pair the sensor already on the arm: the eavesdropping upgrade path.
    var pairCurrentSensor: (() -> Void)
    @ObservedObject var viewModel: G7SettingsViewModel

    @Environment(\.appName) private var appName
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingDeletionSheet = false
    @State private var showingCalibration = false
    @State private var showingShareSignIn = false
    @State private var showingDexcomAppModeConfirmation = false
    @State private var showingDexcomAppModeInstructions = false

    init(didFinish: @escaping () -> Void, deleteCGM: @escaping () -> Void, pairNewSensor: @escaping () -> Void, pairCurrentSensor: @escaping () -> Void, viewModel: G7SettingsViewModel) {
        self.didFinish = didFinish
        self.deleteCGM = deleteCGM
        self.pairNewSensor = pairNewSensor
        self.pairCurrentSensor = pairCurrentSensor
        self.viewModel = viewModel
    }

    /// Weekday, date and time. `j` is the hour in the user's preferred
    /// cycle, so the 24-Hour Time setting is honoured; `hh` would force AM/PM.
    private var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMdjmm")
        return formatter
    }()

    var body: some View {
        List {
            Section() {
                sensorCard
                if let message = sessionMessage {
                    Text(message)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            sensorSection
            if let activatedAt = viewModel.activatedAt {
                HStack {
                    Text(LocalizedString("Sensor Start", comment: "title for g7 settings row showing sensor start time"))
                    Spacer()
                    Text(timeFormatter.string(from: activatedAt))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text(LocalizedString("Sensor Expiration", comment: "title for g7 settings row showing sensor expiration time"))
                    Spacer()
                    Text(timeFormatter.string(from: activatedAt.addingTimeInterval(viewModel.lifetime)))
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text(LocalizedString("Grace Period End", comment: "title for g7 settings row showing sensor grace period end time"))
                    Spacer()
                    Text(timeFormatter.string(from: activatedAt.addingTimeInterval(viewModel.lifetime + G7Sensor.gracePeriod)))
                        .foregroundColor(.secondary)
                }
            }

            Section("Bluetooth") {
                if let name = viewModel.sensorName {
                    HStack {
                        Text(LocalizedString("Name", comment: "title for g7 settings row showing BLE Name"))
                        Spacer()
                        Text(name)
                            .foregroundColor(.secondary)
                    }
                }
                if viewModel.scanning {
                    HStack {
                        Text(LocalizedString("Scanning", comment: "title for g7 settings connection status when scanning"))
                        Spacer()
                        SwiftUI.ProgressView()
                    }
                } else {
                    if viewModel.connected {
                        Text(LocalizedString("Connected", comment: "title for g7 settings connection status when connected"))
                    } else if viewModel.sessionMode == .direct {
                        // The sensor drops the link between readings; a spinner
                        // here would spin ~95% of the time and read as broken.
                        Text(LocalizedString("Waiting for next reading", comment: "title for g7 settings connection status between readings in direct mode"))
                    } else {
                        HStack {
                            Text(LocalizedString("Connecting", comment: "title for g7 settings connection status when connecting"))
                            Spacer()
                            SwiftUI.ProgressView()
                        }
                    }
                }
                if let lastConnect = viewModel.lastConnect {
                    LabeledValueView(label: LocalizedString("Last Connect", comment: "title for g7 settings row showing sensor last connect time"),
                                     value: timeFormatter.string(from: lastConnect))
                }
            }

if viewModel.sessionMode == .eavesdropping {
                Section () {
                    Button(LocalizedString("Open Dexcom App", comment:"Opens the dexcom G7 app to allow users to manage active sensors"), action: {
                        G7DexcomApp.open()
                    })
                }
            }

            if viewModel.sessionMode == .direct {
                calibrationSection
                shareSection
            }

            Section () {
                switch viewModel.sessionMode {
                case .direct:
                    Button(LocalizedString("Pair New Sensor", comment: "Button title in settings to pair a replacement sensor"), action: pairNewSensor)
                    Button(LocalizedString("Use with the Dexcom App Instead", comment: "Button title in settings to go back to reading through the Dexcom app"), action: { showingDexcomAppModeConfirmation = true })
                case .eavesdropping:
                    if !self.viewModel.scanning {
                        Button("Scan for new sensor", action: {
                            self.viewModel.scanForNewSensor()
                        })
                    }
                }

                deleteCGMButton
            }
        }
        .insetGroupedListStyle()
        .navigationBarItems(trailing: doneButton)
        .sheet(isPresented: $showingCalibration) {
            G7CalibrationFlowView(viewModel: viewModel)
        }
        .confirmationDialog(
            LocalizedString("Use with the Dexcom App Instead?", comment: "Title of the confirmation for switching back to the Dexcom app's session"),
            isPresented: $showingDexcomAppModeConfirmation,
            titleVisibility: .visible
        ) {
            Button(LocalizedString("Switch to the Dexcom App", comment: "Confirmation button to switch back to the Dexcom app's session")) {
                viewModel.switchToDexcomAppMode()
                showingDexcomAppModeInstructions = true
            }
            Button(LocalizedString("Cancel", comment: "Button text to cancel G7 setup"), role: .cancel) {}
        } message: {
            Text(String(format: LocalizedString("%1$@ will let go of the sensor and read through the Dexcom app's session again. Glucose and sensor alerts then come from the Dexcom app, and %1$@ stops uploading to Dexcom Share. You can pair directly again later with the sensor's code.", comment: "Message of the confirmation for switching back to the Dexcom app's session (1: appName)"), appName))
        }
        .alert(
            LocalizedString("Now Set Up the Dexcom App", comment: "Title of the instructions after switching back to the Dexcom app's session"),
            isPresented: $showingDexcomAppModeInstructions
        ) {
            Button(LocalizedString("OK", comment: "Alert acknowledgment button label"), role: .cancel) {}
        } message: {
            Text(String(format: LocalizedString("Install the Dexcom app, sign in, and add this sensor with its 4-digit pairing code%1$@. The sensor may take up to 15 minutes to accept the Dexcom app. %2$@ will show readings again once the Dexcom app is connected.", comment: "Instructions after switching back to the Dexcom app's session (1: the pairing code, if known; 2: appName)"), viewModel.pairingCode.map { " (" + $0 + ")" } ?? "", appName))
        }
        .sheet(isPresented: $showingShareSignIn) {
            NavigationView {
                G7ShareSignInView(
                    signIn: { try await viewModel.signInToShare($0) },
                    didFinish: { showingShareSignIn = false }
                )
                .navigationBarItems(leading: Button(LocalizedString("Cancel", comment: "Button text to cancel G7 setup")) { showingShareSignIn = false })
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.refreshEnvironment()
            }
        }
    }

    /// How readings reach the app, and whatever the Dexcom app's presence
    /// means for that.
    @ViewBuilder
    /// What we know about the sensor itself: model, identity, and what it
    /// reported about its own firmware and session. Mode-specific notices
    /// and the pairing actions live here too.
    private var sensorSection: some View {
        Section(header: Text(LocalizedString("Sensor", comment: "Section header for sensor details"))) {
            // Eavesdropping sessions lead with the way out of them.
            if viewModel.sessionMode == .eavesdropping {
            if viewModel.isDexcomAppInstalled {
                warning(
                    title: LocalizedString("Direct Connection Available (Optional)", comment: "Title of the settings notice offering to pair directly"),
                    message: String(format: LocalizedString("%1$@ is reading glucose through the Dexcom app's session, and can keep doing so. If you would rather not depend on the Dexcom app, pair the sensor directly instead: you will need the sensor's 4-digit pairing code, and the Dexcom app has to come off this phone first: delete it, or offload it under Settings, General, iPhone Storage. You can switch back later.", comment: "Body of the settings notice offering to pair directly (1: appName)"), appName),
                    style: .informational
                )
            } else {
                warning(
                    title: LocalizedString("Dexcom App Not Found", comment: "Title of the settings warning when the Dexcom app is missing in eavesdropping mode"),
                    message: String(format: LocalizedString("In this mode %1$@ can only read glucose while the Dexcom G7 app is installed and running a session. Pair the sensor directly instead, or reinstall the Dexcom app.", comment: "Body of the settings warning when the Dexcom app is missing in eavesdropping mode (1: appName)"), appName),
                    style: .critical
                )
            }
            Button(LocalizedString("Pair Sensor Directly", comment: "Button title in settings to upgrade an eavesdropping session to direct pairing"), action: pairCurrentSensor)
            }
            LabeledValueView(
                label: LocalizedString("Model", comment: "Row label for the sensor model"),
                value: viewModel.sensorModelName
            )
            if let serialNumber = viewModel.serialNumber {
                copyableRow(
                    label: LocalizedString("Serial Number", comment: "title for g7 settings row showing the sensor serial number"),
                    value: serialNumber
                )
            }
            if viewModel.sessionMode == .direct, let pairingCode = viewModel.pairingCode {
                // The applicator gets thrown away; this is where the code
                // lives afterwards, for pairing the same sensor elsewhere.
                copyableRow(
                    label: LocalizedString("Pairing Code", comment: "Row label for the sensor's pairing code"),
                    value: pairingCode
                )
            }
            if let firmwareVersion = viewModel.firmwareVersion {
                LabeledValueView(
                    label: LocalizedString("Firmware", comment: "title for g7 settings row showing the sensor firmware version"),
                    value: firmwareVersion
                )
            }
            if let softwareNumber = viewModel.softwareNumber {
                LabeledValueView(
                    label: LocalizedString("Software Number", comment: "Row label for the sensor's software number"),
                    value: softwareNumber
                )
            }
            if let hardwareVersion = viewModel.hardwareVersion {
                LabeledValueView(
                    label: LocalizedString("Hardware Version", comment: "Row label for the sensor's hardware version"),
                    value: hardwareVersion
                )
            }
            if let siliconVersion = viewModel.siliconVersion {
                LabeledValueView(
                    label: LocalizedString("Silicon Version", comment: "Row label for the sensor's silicon version"),
                    value: siliconVersion
                )
            }
            if let algorithmVersion = viewModel.algorithmVersion {
                LabeledValueView(
                    label: LocalizedString("Algorithm Version", comment: "Row label for the sensor's algorithm version"),
                    value: algorithmVersion
                )
            }
            if viewModel.hasReportedLifetime {
                LabeledValueView(
                    label: LocalizedString("Session Length", comment: "Row label for the sensor's session length"),
                    value: sessionLengthFormatter.string(from: viewModel.lifetime) ?? ""
                )
                LabeledValueView(
                    label: LocalizedString("Warmup", comment: "Row label for the sensor's warmup duration"),
                    value: sessionLengthFormatter.string(from: viewModel.warmupDuration) ?? ""
                )
            }
            if let pairedAt = viewModel.pairedAt {
                LabeledValueView(
                    label: LocalizedString("Paired", comment: "Row label for when the sensor was paired"),
                    value: timeFormatter.string(from: pairedAt)
                )
            }
            if let previousSensor = viewModel.previousSensor {
                NavigationLink(destination: G7PreviousSensorView(record: previousSensor)) {
                    HStack {
                        Text(LocalizedString("Previous Sensor", comment: "Row label linking to the previous sensor page"))
                        Spacer()
                        if previousSensor.failureMessage != nil {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(guidanceColors.critical)
                        }
                        Text(previousSensor.model?.displayName(sessionLength: previousSensor.sessionLength) ?? previousSensor.sensorID)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if viewModel.sessionMode == .direct {
                if viewModel.needsNewSensor {
                    // The one thing to do now; the same button also lives at
                    // the bottom of the screen, but this is where the eye lands
                    // after tapping an "expired" status.
                    Button(action: pairNewSensor) {
                        Label(LocalizedString("Pair New Sensor", comment: "Button title in settings to pair a replacement sensor"), systemImage: "plus.circle.fill")
                            .font(.headline)
                    }
                }
                if let failure = viewModel.lastAuthenticationFailure {
                    warning(
                        title: LocalizedString("Sensor Refused Connection", comment: "Title of the settings warning after the sensor refused authentication"),
                        message: failure + (viewModel.lastAuthenticationFailureDate.map { " (" + timeFormatter.string(from: $0) + ")" } ?? ""),
                        style: .critical
                    )
                }
                if viewModel.isDexcomAppInstalled {
                    warning(
                        title: String(format: LocalizedString("Stop the %@ App", comment: "Title of the settings warning when a Dexcom app is installed in direct mode (1: app name)"), G7DexcomApp.installedAppNames),
                        message: String(format: LocalizedString("%1$@ is connected to the sensor directly and does not need the %2$@ app. A sensor works with only one app at a time, so it will take readings away for as long as it is on this phone. Delete it, or offload it under Settings, General, iPhone Storage.", comment: "Body of the settings warning when a Dexcom app is installed in direct mode (1: appName, 2: Dexcom app name)"), appName, G7DexcomApp.installedAppNames),
                        style: .critical
                    )
                }

            }
        }
    }

    @State private var copiedValue: String?

    /// A value row that copies on tap (and offers Copy in its context menu),
    /// confirming briefly in place. For things like the serial number that
    /// end up typed into support forms and Dexcom's website.
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

    /// Calibration is a direct-mode command; an eavesdropper can only listen.
    private var calibrationSection: some View {
        Section(header: Text(LocalizedString("Calibration", comment: "Section header for sensor calibration"))) {
            if let calibration = viewModel.calibration {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(LocalizedString("Last Calibration", comment: "Row label for the last calibration entered"))
                        Spacer()
                        Text(viewModel.formatGlucose(mgdl: Double(calibration.glucose)))
                            .foregroundColor(.secondary)
                    }
                    Text(calibrationOutcomeText(calibration))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else if let bounds = viewModel.calibrationBounds, bounds.hasCalibration {
                // Calibrated by another display (the Dexcom app, before the switch).
                LabeledValueView(
                    label: LocalizedString("Last Calibration", comment: "Row label for the last calibration entered"),
                    value: LocalizedString("By another app", comment: "Last calibration value when the sensor reports one this app did not enter")
                )
            } else {
                LabeledValueView(
                    label: LocalizedString("Last Calibration", comment: "Row label for the last calibration entered"),
                    value: LocalizedString("None", comment: "Last calibration value when the sensor has not been calibrated")
                )
            }

            if viewModel.hasPendingCalibration {
                Button(action: viewModel.cancelPendingCalibration) {
                    Text(LocalizedString("Cancel Pending Calibration", comment: "Button title to drop a calibration not yet sent"))
                        .foregroundColor(guidanceColors.critical)
                }
            } else {
                Button(action: { showingCalibration = true }) {
                    Text(LocalizedString("Calibrate", comment: "Button title to start calibrating the sensor"))
                }
                .disabled(!viewModel.canCalibrate)
            }
        }
    }

    /// Uploading to Dexcom Share, so followers keep seeing readings without
    /// the Dexcom app. Direct mode only: while eavesdropping the Dexcom app
    /// is uploading itself.
    private var shareSection: some View {
        Section(header: Text(LocalizedString("Dexcom Share", comment: "Section header for Dexcom Share upload"))) {
            if let username = viewModel.shareUsername {
                LabeledValueView(
                    label: LocalizedString("Account", comment: "Row label for the signed-in Dexcom Share account"),
                    value: username
                )
                if let lastUploadAt = viewModel.shareUploadStatus.lastUploadAt {
                    LabeledValueView(
                        label: LocalizedString("Last Upload", comment: "Row label for the last Dexcom Share upload time"),
                        value: timeFormatter.string(from: lastUploadAt)
                    )
                }
                if let error = viewModel.shareUploadStatus.lastError {
                    warning(
                        title: LocalizedString("Upload Problem", comment: "Title of the Dexcom Share upload error notice"),
                        message: error + (viewModel.shareUploadStatus.lastErrorAt.map { " (" + timeFormatter.string(from: $0) + ")" } ?? ""),
                        style: .critical
                    )
                } else if viewModel.shareUploadStatus.lastUploadAt == nil {
                    Text(LocalizedString("Waiting for the first reading to upload.", comment: "Dexcom Share status before the first upload"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                if let client = viewModel.shareClient {
                    NavigationLink(destination: G7ShareFollowersView(client: client)) {
                        Text(LocalizedString("Followers", comment: "Row label opening the followers page"))
                    }
                }
                Button(action: viewModel.signOutOfShare) {
                    Text(LocalizedString("Sign Out", comment: "Button title to sign out of Dexcom Share"))
                        .foregroundColor(guidanceColors.critical)
                }
            } else {
                Button(action: { showingShareSignIn = true }) {
                    Text(LocalizedString("Sign In to Dexcom Share", comment: "Button title to sign in to Dexcom Share from settings"))
                }
                Text(LocalizedString("Send readings to Dexcom Share so followers keep seeing your glucose in the Dexcom Follow app.", comment: "Dexcom Share section footnote when signed out"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func calibrationOutcomeText(_ calibration: G7CalibrationRecord) -> String {
        let entered = timeFormatter.string(from: calibration.enteredAt)
        switch calibration.outcome {
        case .pending:
            return String(format: LocalizedString("Entered %@, waiting for the sensor's next connection", comment: "Calibration outcome: pending (1: time entered)"), entered)
        case .rejected(let status, _):
            return String(format: LocalizedString("Entered %1$@, refused by the sensor (status %2$d)", comment: "Calibration outcome: rejected (1: time entered, 2: status code)"), entered, Int(status))
        case .accepted(let at):
            switch calibration.processingStatus {
            case .inProgress?:
                return String(format: LocalizedString("Accepted %@; the sensor is still applying it", comment: "Calibration outcome: accepted, processing (1: time accepted)"), timeFormatter.string(from: at))
            case .completeHigh?, .completeLow?:
                return String(format: LocalizedString("Accepted %@ and applied", comment: "Calibration outcome: accepted and applied (1: time accepted)"), timeFormatter.string(from: at))
            default:
                return String(format: LocalizedString("Accepted %@", comment: "Calibration outcome: accepted (1: time accepted)"), timeFormatter.string(from: at))
            }
        }
    }

    private enum WarningStyle {
        case informational, critical
    }

    private func warning(title: String, message: String, style: WarningStyle) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: style == .critical ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundColor(style == .critical ? guidanceColors.critical : .accentColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
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
                message: viewModel.sessionMode == .direct
                    ? Text(LocalizedString("The sensor stays reserved for this phone for about 15 minutes. To use it with another app, wait that long, then forget the sensor under Settings > Bluetooth before pairing there.", comment: "Delete CGM sheet message in direct mode about the sensor lease and iOS bond"))
                    : nil,
                buttons: [
                    .destructive(Text("Delete CGM")) {
                        self.deleteCGM()
                    },
                    .cancel(),
                ]
            )
        }
    }

    /// Whether the session is over and the sensor needs replacing: the card
    /// dims the image and the reading row turns into a call to action.
    private var sessionIsOver: Bool {
        switch viewModel.lifecycleState {
        case .expired, .failed:
            return true
        case .unpaired, .searching, .connecting, .warmup, .ok, .gracePeriod:
            return false
        }
    }

    private var sensorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            viewModel.sensorModel.image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .opacity(sessionIsOver || viewModel.lifecycleState == .searching ? 0.4 : 1)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(progressLabel)
                        .foregroundColor(progressLabelColor)
                    Spacer()
                    remainingTime
                }
                G7LifecycleBar(
                    progress: viewModel.progressBarProgress,
                    color: sessionIsOver ? Color(.systemGray3) : color(for: viewModel.progressBarColorStyle)
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedString("Last reading", comment: "Label above the last reading row on the sensor card"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                HStack(alignment: .center) {
                    lastReadingValue
                    Spacer()
                    lastReadingAge
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Progress line

    private var progressLabel: String {
        switch viewModel.lifecycleState {
        case .unpaired:
            return LocalizedString("No sensor paired", comment: "Sensor card label when the CGM has been added but no sensor paired")
        case .searching:
            return LocalizedString("Searching for sensor", comment: "Sensor card label while searching")
        case .connecting:
            return LocalizedString("Waiting for first reading", comment: "Sensor card label after pairing, before the first reading")
        case .warmup:
            return LocalizedString("Warmup completes in", comment: "Sensor card label during warmup, followed by the remaining time")
        case .ok:
            return LocalizedString("Sensor expires in", comment: "Sensor card label during the session, followed by the remaining time")
        case .gracePeriod:
            return LocalizedString("Sensor expired", comment: "Sensor card label during the grace period")
        case .expired:
            if let endsAt = viewModel.sensorEndsAt {
                return String(format: LocalizedString("Session ended at %@", comment: "Sensor card label once the session is over (1: end time)"), sessionEndFormatter.string(from: endsAt))
            }
            return LocalizedString("Session ended", comment: "Sensor card label once the session is over")
        case .failed:
            return LocalizedString("Sensor failed", comment: "Sensor card label after a sensor failure")
        }
    }

    private var progressLabelColor: Color {
        switch viewModel.lifecycleState {
        case .gracePeriod, .failed:
            return guidanceColors.critical
        case .unpaired, .searching, .connecting, .expired, .warmup, .ok:
            return .secondary
        }
    }

    /// The remaining time as big numbers with small units: the two largest
    /// nonzero units abbreviated ("1 hr 50 min", "9 days 3 hr"), or a single
    /// unit spelled out ("2 hours", "30 mins").
    @ViewBuilder
    private var remainingTime: some View {
        switch viewModel.lifecycleState {
        case .warmup, .ok:
            if let remaining = viewModel.progressValue {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    ForEach(Array(remainingComponents(remaining).enumerated()), id: \.offset) { _, component in
                        Text(component.value)
                            .font(.system(size: 28, weight: .bold))
                        Text(component.unit)
                            .foregroundColor(.secondary)
                    }
                }
            }
        case .unpaired, .searching, .connecting, .gracePeriod, .expired, .failed:
            EmptyView()
        }
    }

    private func remainingComponents(_ interval: TimeInterval) -> [(value: String, unit: String)] {
        let totalMinutes = max(0, Int((interval / 60).rounded(.up)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            if hours > 0 {
                return [
                    (String(days), LocalizedString("days", comment: "Abbreviated days unit after a remaining-time number")),
                    (String(hours), LocalizedString("hr", comment: "Abbreviated hours unit after a remaining-time number"))
                ]
            }
            return [(String(days), days == 1
                ? LocalizedString("day", comment: "Unit after a remaining-time number, singular")
                : LocalizedString("days", comment: "Unit after a remaining-time number, plural"))]
        }
        if hours > 0 {
            if minutes > 0 {
                return [
                    (String(hours), LocalizedString("hr", comment: "Abbreviated hours unit after a remaining-time number")),
                    (String(minutes), LocalizedString("min", comment: "Abbreviated minutes unit after a remaining-time number"))
                ]
            }
            return [(String(hours), hours == 1
                ? LocalizedString("hour", comment: "Unit after a remaining-time number, singular")
                : LocalizedString("hours", comment: "Unit after a remaining-time number, plural"))]
        }
        return [(String(minutes), minutes == 1
            ? LocalizedString("min", comment: "Unit after a remaining-time number, singular")
            : LocalizedString("mins", comment: "Unit after a remaining-time number, plural"))]
    }

    private var sessionEndFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        if let endsAt = viewModel.sensorEndsAt, !Calendar.current.isDateInToday(endsAt) {
            formatter.dateStyle = .short
        }
        return formatter
    }

    // MARK: Last reading row

    @ViewBuilder
    private var lastReadingValue: some View {
        if sessionIsOver {
            HStack(spacing: 8) {
                badge(systemName: "exclamationmark", color: guidanceColors.critical)
                Text(LocalizedString("Replace Sensor", comment: "Last reading row text once the session is over"))
                    .font(.headline)
                    .lineLimit(2)
            }
        } else if viewModel.hasLastGlucose {
            HStack(spacing: 8) {
                if let trend = viewModel.lastGlucoseTrend {
                    badge(text: trend.symbol, color: glucoseTintColor)
                } else {
                    badge(systemName: "minus", color: glucoseTintColor)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(viewModel.lastGlucoseValueString)
                        .font(.system(size: 28, weight: .bold))
                    Text(viewModel.displayGlucosePreference.unit.shortLocalizedUnitString())
                        .foregroundColor(.secondary)
                }
            }
        } else if viewModel.lifecycleState == .warmup {
            HStack(spacing: 8) {
                outlinedBadge(systemName: "clock", color: glucoseTintColor)
                Text(LocalizedString("Sensor Warmup", comment: "Last reading row text during warmup"))
                    .font(.headline)
                    .lineLimit(2)
            }
        } else {
            Text(LocalizedString("– – –", comment: "No glucose value representation (3 dashes for mg/dL)"))
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.secondary)
        }
    }

    /// Minutes since the last reading, live. Readings are 5 minutes apart,
    /// so past 10 something is late and past 20 something is wrong.
    @ViewBuilder
    private var lastReadingAge: some View {
        if let latest = viewModel.latestReadingTimestamp {
            TimelineView(.everyMinute) { context in
                let minutes = max(0, Int(context.date.timeIntervalSince(latest) / 60))
                let color: Color = minutes > 20 ? guidanceColors.critical : (minutes > 10 ? guidanceColors.warning : glucoseTintColor)
                HStack(spacing: 8) {
                    badge(systemName: "arrow.triangle.2.circlepath", color: color)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(minutes < 90 ? String(minutes) : String(minutes / 60))
                            .font(.system(size: 28, weight: .bold))
                        Text(minutes < 90
                            ? LocalizedString("min", comment: "Unit after the minutes-since-last-reading number")
                            : LocalizedString("hr", comment: "Unit after the hours-since-last-reading number"))
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func badge(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(color))
    }

    /// A hollow variant, for states that are pending rather than alarming.
    private func outlinedBadge(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(color)
            .frame(width: 28, height: 28)
            .overlay(Circle().stroke(color, lineWidth: 2))
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(color))
    }

    // MARK: Message

    private var sessionMessage: String? {
        switch viewModel.lifecycleState {
        case .gracePeriod:
            return LocalizedString("Your sensor has reached the end of its session. Readings continue for up to 12 hours; replace your sensor before then.", comment: "Sensor card message during the grace period")
        case .expired:
            return LocalizedString("Replace your sensor now. You will not receive glucose readings until you do.", comment: "Sensor card message once the session is over")
        case .failed:
            return LocalizedString("Your sensor has stopped working. Remove it and replace it now; you will not receive glucose readings until you do.", comment: "Sensor card message after a sensor failure")
        case .warmup:
            return String(format: LocalizedString("Your sensor is warming up. You will not receive alerts, alarms, or glucose readings during the %@ warmup.", comment: "Sensor card message during warmup (1: warmup duration, e.g. 30-minute)"), warmupDurationString)
        case .unpaired:
            return LocalizedString("Pair a sensor to start receiving glucose readings.", comment: "Sensor card message when the CGM has been added but no sensor paired")
        case .searching, .connecting, .ok:
            return nil
        }
    }

    /// "30-minute" or "1-hour", for the warmup message.
    private var warmupDurationString: String {
        let minutes = Int((viewModel.warmupDuration / 60).rounded())
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return String(format: LocalizedString("%d-hour", comment: "Warmup duration in hours, adjectival (1: hours)"), hours)
        }
        return String(format: LocalizedString("%d-minute", comment: "Warmup duration in minutes, adjectival (1: minutes)"), minutes)
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
