//
//  G7CalibrationFlowView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import G7SensorKit
import LoopKitUI
import SwiftUI

/// Calibration: the why and how advice the first time, then straight to
/// the entry page once it has been reached.
struct G7CalibrationFlowView: View {
    @ObservedObject var viewModel: G7SettingsViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Inside the pushed pages `dismiss` would only pop; the sheet's own
        // dismiss is handed down for when the calibration is sent.
        NavigationView {
            Group {
                if viewModel.calibrationAdviceSeen {
                    G7CalibrationEntryView(viewModel: viewModel, didFinish: { dismiss() })
                } else {
                    G7CalibrationWhyView(viewModel: viewModel, didFinish: { dismiss() })
                }
            }
            .navigationBarItems(leading: Button(LocalizedString("Cancel", comment: "Button text to cancel G7 setup")) {
                dismiss()
            })
        }
    }
}

/// Page 1 of the first-time advice: whether to calibrate at all.
struct G7CalibrationWhyView: View {
    @ObservedObject var viewModel: G7SettingsViewModel
    var didFinish: () -> Void

    var body: some View {
        ScrollView {
            G7CalibrationWhyContent()
                .padding()
        }
        .safeAreaInset(edge: .bottom) {
            NavigationLink(destination: G7CalibrationHowView(viewModel: viewModel, didFinish: didFinish)) {
                Text(LocalizedString("Continue", comment: "Button title to continue"))
                    .actionButtonStyle(.primary)
            }
            .padding()
            .background(Color(.systemBackground))
        }
        .navigationBarTitle(Text(LocalizedString("Before You Calibrate", comment: "Calibration why-page: navigation title and header text")), displayMode: .inline)
    }
}

private struct G7CalibrationWhyContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "drop.fill")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                Text(LocalizedString("Before You Calibrate", comment: "Calibration why-page: navigation title and header text"))
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            Text(LocalizedString("The G7 is factory calibrated and does not need calibrating. Calibrating tells the sensor to trust your meter over itself, so it is only worth doing when a small, steady offset has been there for hours and you have confirmed it with more than one fingerstick.", comment: "Calibration advice: calibration is optional"))
                .fixedSize(horizontal: false, vertical: true)

            calibrationAdviceRow(
                icon: "exclamationmark.triangle",
                title: LocalizedString("A big difference is a reason for caution, not a reason to calibrate", comment: "Calibration advice heading: large differences"),
                body: LocalizedString("A large gap is usually temporary: pressure on the sensor while you sleep, a new sensor still settling, or a fast change the sensor has not caught up with. Calibrating to it makes a big correction to the algorithm, and when the cause passes the readings swing just as far the other way. Wait it out and check again; if the gap stays large, replace the sensor.", comment: "Calibration advice: large differences")
            )
        }
    }
}

/// Page 2 of the first-time advice: how to calibrate well.
struct G7CalibrationHowView: View {
    @ObservedObject var viewModel: G7SettingsViewModel
    var didFinish: () -> Void

    var body: some View {
        ScrollView {
            G7CalibrationHowContent(viewModel: viewModel)
                .padding()
        }
        .safeAreaInset(edge: .bottom) {
            NavigationLink(destination: G7CalibrationEntryView(viewModel: viewModel, didFinish: didFinish)) {
                Text(LocalizedString("Continue", comment: "Button title to continue"))
                    .actionButtonStyle(.primary)
            }
            .padding()
            .background(Color(.systemBackground))
        }
        .navigationBarTitle(Text(LocalizedString("How to Calibrate", comment: "Calibration how-page: navigation title and header text")), displayMode: .inline)
    }
}

/// The full advice, why and how on one sheet, opened from the entry page.
struct G7CalibrationAdviceSheet: View {
    @ObservedObject var viewModel: G7SettingsViewModel
    var didFinish: () -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    G7CalibrationWhyContent()
                    Divider()
                    G7CalibrationHowContent(viewModel: viewModel)
                }
                .padding()
            }
            .navigationBarTitle(Text(LocalizedString("Before You Calibrate", comment: "Navigation title of the full calibration advice sheet")), displayMode: .inline)
            .navigationBarItems(trailing: Button(LocalizedString("Done", comment: "Button to dismiss a sheet")) { didFinish() })
        }
    }
}

private struct G7CalibrationHowContent: View {
    @ObservedObject var viewModel: G7SettingsViewModel

    @Environment(\.guidanceColors) private var guidanceColors

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "checklist")
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                Text(LocalizedString("How to Calibrate", comment: "Calibration how-page: navigation title and header text"))
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            calibrationAdviceRow(
                icon: "arrow.right",
                title: LocalizedString("Only when glucose is stable", comment: "Calibration advice heading: stability"),
                body: LocalizedString("A flat trend, and nothing that will move it: no meal, insulin, correction or exercise in the last hour or so, and not while treating a low. The sensor lags blood glucose by several minutes, so a calibration taken while glucose is changing teaches it the wrong number.", comment: "Calibration advice: stability")
            )

            calibrationAdviceRow(
                icon: "clock",
                title: LocalizedString("Not on the first day", comment: "Calibration advice heading: timing"),
                body: LocalizedString("The sensor refuses calibrations during warmup, and readings are still settling for the first 12 to 24 hours. Give it a day before deciding it is off.", comment: "Calibration advice: timing")
            )

            calibrationAdviceRow(
                icon: "hand.raised",
                title: LocalizedString("Wash your hands first", comment: "Calibration advice heading: clean hands"),
                body: LocalizedString("Clean and dry your hands thoroughly with soap and water before testing. Sugar or lotion on a finger gives a false meter reading, and the calibration would carry it into the sensor.", comment: "Calibration advice: clean hands")
            )

            calibrationAdviceRow(
                icon: "drop.triangle",
                title: LocalizedString("Fingersticks only", comment: "Calibration advice heading: fingersticks only"),
                body: LocalizedString("Calibrate only with a blood glucose meter, and enter the value within five minutes of the test. Never calibrate from another CGM's reading.", comment: "Calibration advice: fingersticks only")
            )

            if let stabilityNote = stabilityNote {
                Label(stabilityNote, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(guidanceColors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Whether the last reading says now is a bad moment.
    private var stabilityNote: String? {
        guard let trend = viewModel.lastTrendMgdlPerMinute else { return nil }
        if abs(trend) >= 1 {
            return LocalizedString("Your glucose is changing right now. Wait until the trend is flat.", comment: "Calibration advice warning: trend is not flat")
        }
        return nil
    }
}

/// One icon + title + body row, shared by the why and how advice pages.
private func calibrationAdviceRow(icon: String, title: String, body: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
        Image(systemName: icon)
            .font(.title3)
            .foregroundColor(.accentColor)
            .frame(width: 28)
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The meter value, checked against the sensor's reading before it is sent.
struct G7CalibrationEntryView: View {
    @ObservedObject var viewModel: G7SettingsViewModel
    var didFinish: () -> Void

    @Environment(\.guidanceColors) private var guidanceColors

    @State private var text = ""
    @State private var showingLargeDifferenceWarning = false
    @State private var showingAdvice = false
    @FocusState private var fieldFocused: Bool

    /// Difference from the sensor at which the warning steps in (mg/dL).
    static let largeDifferenceMgdl: Double = 40

    private var enteredMgdl: Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return viewModel.mgdl(fromDisplayValue: value)
    }

    private var isValid: Bool {
        guard let mgdl = enteredMgdl else { return false }
        return (Double(GlucoseLimits.minimum)...Double(GlucoseLimits.maximum)).contains(mgdl)
    }

    private var differenceMgdl: Double? {
        guard let entered = enteredMgdl, let current = viewModel.lastGlucoseMgdl else { return nil }
        return entered - current
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text(LocalizedString("Sensor Reading", comment: "Calibration entry row: the sensor's current value"))
                    Spacer()
                    Text(viewModel.lastGlucoseMgdl.map { viewModel.formatGlucose(mgdl: $0) } ?? "–")
                        .foregroundColor(.secondary)
                    if !viewModel.lastGlucoseTrendString.isEmpty {
                        Text(viewModel.lastGlucoseTrendString)
                            .foregroundColor(.secondary)
                    }
                }
                HStack {
                    Text(LocalizedString("Meter Value", comment: "Calibration entry row: the fingerstick value field"))
                    Spacer()
                    TextField(viewModel.glucoseUnitString, text: $text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($fieldFocused)
                }
                if let difference = differenceMgdl, isValid {
                    HStack {
                        Text(LocalizedString("Difference", comment: "Calibration entry row: meter minus sensor"))
                        Spacer()
                        Text((difference >= 0 ? "+" : "−") + viewModel.formatGlucose(mgdl: abs(difference)))
                            .foregroundColor(abs(difference) >= G7CalibrationEntryView.largeDifferenceMgdl ? guidanceColors.warning : .secondary)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(LocalizedString("The sensor connects for a few seconds around each reading, so the calibration is sent at the next one, within about five minutes. Until then you can cancel it from the settings screen.", comment: "Calibration entry footer: when the value is sent"))
                    Text(LocalizedString("The G7 is factory calibrated. Calibrate only when glucose is steady.", comment: "Calibration entry: caution shown every time"))
                    Button(action: { showingAdvice = true }) {
                        Label(LocalizedString("Read Before Calibrating", comment: "Button on the calibration entry page that opens the full advice"), systemImage: "info.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .insetGroupedListStyle()
        .sheet(isPresented: $showingAdvice) {
            G7CalibrationAdviceSheet(viewModel: viewModel, didFinish: { showingAdvice = false })
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: submitTapped) {
                Text(LocalizedString("Calibrate", comment: "Button title to send the calibration"))
                    .actionButtonStyle(.primary)
            }
            .disabled(!isValid)
            .padding()
            .background(Color(.systemBackground))
        }
        .onAppear {
            fieldFocused = true
            // Reaching this page is what counts as having read the advice.
            viewModel.markCalibrationAdviceSeen()
        }
        .alert(
            LocalizedString("Large Difference", comment: "Title of the alert for a calibration far from the sensor reading"),
            isPresented: $showingLargeDifferenceWarning
        ) {
            Button(LocalizedString("Cancel", comment: "Button text to cancel G7 setup"), role: .cancel) {}
            Button(LocalizedString("Calibrate Anyway", comment: "Button title to send a calibration despite the large difference")) { submit() }
        } message: {
            Text(String(format: LocalizedString("The meter value is %1$@ from the sensor reading. A gap this large is usually temporary, and calibrating to it makes a large correction that swings the readings the other way once the cause passes. Wait and check again; keep any calibration within %2$@ of the reading, or replace the sensor if the gap stays this large.", comment: "Message of the large difference alert (1: difference with unit, 2: recommended limit with unit)"), viewModel.formatGlucose(mgdl: abs(differenceMgdl ?? 0)), viewModel.formatGlucose(mgdl: G7CalibrationEntryView.largeDifferenceMgdl)))
        }
        .navigationBarTitle(Text(LocalizedString("Meter Value", comment: "Navigation title of the calibration entry page")), displayMode: .inline)
    }

    private func submitTapped() {
        if let difference = differenceMgdl, abs(difference) >= G7CalibrationEntryView.largeDifferenceMgdl {
            showingLargeDifferenceWarning = true
        } else {
            submit()
        }
    }

    private func submit() {
        guard let mgdl = enteredMgdl else { return }
        viewModel.calibrate(mgdl: mgdl)
        didFinish()
    }
}
