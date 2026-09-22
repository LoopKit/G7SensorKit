//
//  G7ShareFollowersView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import G7SensorKit
import LoopKitUI
import SwiftUI

/// The account's followers, with invitations and removal, through the
/// same service the Dexcom app uses. An invited follower gets an email from
/// Dexcom with instructions to accept in the Follow app.
struct G7ShareFollowersView: View {
    let client: G7ShareClient

    @Environment(\.guidanceColors) private var guidanceColors

    @State private var followers: [G7ShareFollower] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingInvite = false

    var body: some View {
        List {
            if let errorMessage = errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(guidanceColors.critical)
                }
            }
            Section {
                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if followers.isEmpty {
                    Text(LocalizedString("No followers yet.", comment: "Followers list: empty"))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(followers) { follower in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(follower.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? follower.contactName)
                            HStack {
                                Text(follower.contactName)
                                if let state = follower.state {
                                    Text("· " + stateDescription(state))
                                }
                            }
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        }
                    }
                    .onDelete(perform: remove)
                }
            } header: {
                Text(LocalizedString("Followers", comment: "Section header for the followers list"))
            } footer: {
                Text(LocalizedString("A new follower receives an email from Dexcom with instructions to sign up for the Dexcom Follow app and accept the invitation. Swipe to remove a follower.", comment: "Followers list footer"))
            }
        }
        .insetGroupedListStyle()
        .navigationBarTitle(Text(LocalizedString("Followers", comment: "Navigation title of the followers page")), displayMode: .inline)
        .navigationBarItems(trailing: Button(action: { showingInvite = true }) {
            Image(systemName: "person.badge.plus")
        })
        .sheet(isPresented: $showingInvite) {
            NavigationView {
                G7ShareInviteFollowerView(client: client) {
                    showingInvite = false
                    reload()
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func stateDescription(_ state: String) -> String {
        switch state.lowercased() {
        case "active", "2": return LocalizedString("following", comment: "Follower state: active")
        case "invited", "1", "pending": return LocalizedString("invited", comment: "Follower state: invitation pending")
        default: return state
        }
    }

    private func reload() {
        isLoading = true
        Task {
            do {
                let list = try await client.listFollowers()
                await MainActor.run {
                    followers = list
                    errorMessage = nil
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func remove(at offsets: IndexSet) {
        let removed = offsets.map { followers[$0] }
        followers.remove(atOffsets: offsets)
        Task {
            for follower in removed {
                do {
                    try await client.removeFollower(contactId: follower.contactId)
                } catch {
                    await MainActor.run { errorMessage = error.localizedDescription }
                }
            }
            await MainActor.run { reload() }
        }
    }
}

/// Who to invite and the alerts they start with. Dexcom emails the rest.
struct G7ShareInviteFollowerView: View {
    let client: G7ShareClient
    var didInvite: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.guidanceColors) private var guidanceColors

    @State private var name = ""
    @State private var displayName = ""
    @State private var email = ""
    @State private var alerts = G7ShareFollowerAlerts()
    @State private var isSending = false
    @State private var errorMessage: String?

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && email.contains("@") && !isSending
    }

    var body: some View {
        List {
            Section {
                TextField(LocalizedString("Follower's name", comment: "Invite follower field placeholder"), text: $name)
                    .textContentType(.name)
                TextField(LocalizedString("Email address", comment: "Invite follower field placeholder"), text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(LocalizedString("Your name, as shown to them", comment: "Invite follower field placeholder for the publisher's display name"), text: $displayName)
                    .textContentType(.nickname)
            } footer: {
                Text(LocalizedString("Dexcom emails the invitation. The follower accepts it in the Dexcom Follow app.", comment: "Invite follower footer"))
            }

            Section(header: Text(LocalizedString("Starting Alerts", comment: "Section header for a new follower's initial alert settings"))) {
                Toggle(isOn: $alerts.urgentLowEnabled) {
                    thresholdLabel(LocalizedString("Urgent Low", comment: "Follower alert: urgent low"), alerts.urgentLowThreshold)
                }
                Stepper(value: $alerts.urgentLowThreshold, in: 40...80, step: 5) { EmptyView() }.labelsHidden().disabled(!alerts.urgentLowEnabled)
                Toggle(isOn: $alerts.lowEnabled) {
                    thresholdLabel(LocalizedString("Low", comment: "Follower alert: low"), alerts.lowThreshold)
                }
                Stepper(value: $alerts.lowThreshold, in: 60...150, step: 5) { EmptyView() }.labelsHidden().disabled(!alerts.lowEnabled)
                Toggle(isOn: $alerts.highEnabled) {
                    thresholdLabel(LocalizedString("High", comment: "Follower alert: high"), alerts.highThreshold)
                }
                Stepper(value: $alerts.highThreshold, in: 120...400, step: 10) { EmptyView() }.labelsHidden().disabled(!alerts.highEnabled)
                Toggle(LocalizedString("No Data (1 hour)", comment: "Follower alert: no data"), isOn: $alerts.noDataEnabled)
            }

            if let errorMessage = errorMessage {
                Section {
                    Text(errorMessage).foregroundColor(guidanceColors.critical)
                }
            }
        }
        .insetGroupedListStyle()
        .navigationBarTitle(Text(LocalizedString("Invite Follower", comment: "Navigation title of the invite follower page")), displayMode: .inline)
        .navigationBarItems(
            leading: Button(LocalizedString("Cancel", comment: "Button text to cancel G7 setup")) { dismiss() },
            trailing: Button(action: submit) {
                if isSending { ProgressView() } else { Text(LocalizedString("Invite", comment: "Button title to send a follower invitation")) }
            }.disabled(!canSubmit)
        )
    }

    private func thresholdLabel(_ title: String, _ mgdl: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(mgdl) mg/dL").foregroundColor(.secondary)
        }
    }

    private func submit() {
        isSending = true
        errorMessage = nil
        let shownName = displayName.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                _ = try await client.inviteFollower(
                    name: name.trimmingCharacters(in: .whitespaces),
                    email: email.trimmingCharacters(in: .whitespaces),
                    displayName: shownName.isEmpty ? name.trimmingCharacters(in: .whitespaces) : shownName,
                    alerts: alerts
                )
                await MainActor.run {
                    isSending = false
                    didInvite()
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
