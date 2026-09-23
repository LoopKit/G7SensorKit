//
//  G7EnterCodeView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import G7SensorKit
import SwiftUI

/// Collects the 4-digit pairing code by typing.
///
/// Scanning the applicator lives one screen back, in `G7ScanCodeView`, which
/// is also where a scan's serial number comes from. Someone who arrives here
/// has chosen to type, or has no camera to scan with, so this screen does one
/// thing and raises the keyboard to do it.
struct G7EnterCodeView: View {
    var didEnterCode: (_ code: String) -> Void

    @State private var code = ""

    @FocusState private var codeFieldFocused: Bool

    private var isValid: Bool {
        G7PairingService.isValidPairingCode(code)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(LocalizedString("Enter the 4-digit pairing code printed on the sensor applicator.", comment: "Instructions on the screen where the pairing code is typed by hand"))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(.secondary)

            ZStack {
                TextField("", text: $code)
                    .focused($codeFieldFocused)
                    .keyboardType(.numberPad)
                    .disableAutocorrection(true)
                    .foregroundColor(.clear)
                    .accentColor(.clear)
                    .opacity(0.02)
                    .onChange(of: code) { _, newValue in
                        // Sanitising re-enters this handler, so wait for
                        // the second pass before acting on the code.
                        let sanitized = String(newValue.filter(\.isNumber).prefix(4))
                        guard sanitized == newValue else {
                            code = sanitized
                            return
                        }
                        autoSubmitIfComplete()
                    }

                HStack(spacing: 14) {
                    ForEach(0 ..< 4, id: \.self) { index in
                        let characters = Array(code)
                        let character = index < characters.count ? String(characters[index]) : ""
                        let isActive = index == characters.count

                        Text(character)
                            .font(.title.weight(.semibold).monospaced())
                            .frame(width: 68, height: 68)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.primary.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.accentColor, lineWidth: isActive ? 2 : 0)
                            )
                    }
                }
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)
            }
            .frame(height: 68)
            .contentShape(Rectangle())
            .onTapGesture { codeFieldFocused = true }

            Spacer()

            Button(action: { didEnterCode(code) }) {
                Text(LocalizedString("Continue", comment: "Button title for starting setup"))
                    .actionButtonStyle(.primary)
            }
            .disabled(!isValid)
        }
        .padding()
        // Tap-to-dismiss on the whole screen fought the boxes' own tap
        // gesture: one tap could set focus and clear it.
        .onAppear {
            // Focusing during the push lays the keyboard out against a
            // container with no width yet, which is the TUIKeyplane
            // constraint break. Let the transition settle first.
            DispatchQueue.main.asyncAfter(deadline: .now() + G7EnterCodeView.focusDelay) {
                codeFieldFocused = true
            }
        }
    }

    /// Outlasts a navigation push without the keyboard feeling late.
    private static let focusDelay: TimeInterval = 0.45

    /// A complete code submits itself: with the boxes full there is nothing
    /// left to enter and the number pad has no return key to dismiss it. The
    /// delay lets the last box fill and the keyboard finish leaving, so its
    /// dismissal does not overlap the next screen's push.
    private func autoSubmitIfComplete() {
        guard isValid, codeFieldFocused else { return }

        codeFieldFocused = false
        let submitted = code
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard code == submitted else { return }
            didEnterCode(submitted)
        }
    }
}
