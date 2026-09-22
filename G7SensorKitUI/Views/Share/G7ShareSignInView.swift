//
//  G7ShareSignInView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import G7SensorKit
import LoopKitUI
import SwiftUI

/// Collects Dexcom Share credentials and verifies them with the service
/// before they are kept. Used at the end of onboarding (with a Skip) and
/// from settings.
struct G7ShareSignInView: View {
    /// Signs in; throws the service's refusal.
    var signIn: (G7ShareCredentials) async throws -> Void
    var didFinish: () -> Void
    /// Shown in onboarding, where signing in is optional.
    var didSkip: (() -> Void)?

    @Environment(\.appName) private var appName
    @Environment(\.guidanceColors) private var guidanceColors

    @State private var username = ""
    @State private var password = ""
    @State private var server: G7ShareServer = .us
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !isSigningIn
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: LocalizedString("%1$@ can send readings to Dexcom Share, so your followers keep seeing your glucose in the Dexcom Follow app without the Dexcom app on this phone.", comment: "Share sign-in explanation (1: appName)"), appName))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LocalizedString("Sign in with the Dexcom account that owns the sensor. The password is kept in the keychain on this phone only.", comment: "Share sign-in: which account, where the password goes"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section {
                TextField(LocalizedString("Username or email", comment: "Share sign-in field placeholder"), text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(LocalizedString("Password", comment: "Share sign-in field placeholder"), text: $password)
                    .textContentType(.password)
                Picker(LocalizedString("Region", comment: "Share sign-in server picker label"), selection: $server) {
                    ForEach(G7ShareServer.allCases, id: \.self) { server in
                        Text(server.localizedName).tag(server)
                    }
                }
            } footer: {
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .foregroundColor(guidanceColors.critical)
                }
            }
        }
        .insetGroupedListStyle()
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button(action: submit) {
                    if isSigningIn {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(LocalizedString("Sign In", comment: "Button title to sign in to Dexcom Share"))
                            .actionButtonStyle(.primary)
                    }
                }
                .disabled(!canSubmit)
                if let didSkip = didSkip {
                    Button(action: didSkip) {
                        Text(LocalizedString("Not Now", comment: "Button title to skip Dexcom Share sign-in during setup"))
                            .actionButtonStyle(.secondary)
                    }
                    .disabled(isSigningIn)
                }
            }
            .padding()
            .background(Color(.systemBackground))
        }
        .navigationBarTitle(Text(LocalizedString("Dexcom Share", comment: "Navigation title of the Share sign-in page")), displayMode: .inline)
    }

    private func submit() {
        let credentials = G7ShareCredentials(username: username.trimmingCharacters(in: .whitespaces), password: password, server: server)
        isSigningIn = true
        errorMessage = nil
        Task {
            do {
                try await signIn(credentials)
                await MainActor.run {
                    isSigningIn = false
                    didFinish()
                }
            } catch {
                await MainActor.run {
                    isSigningIn = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
