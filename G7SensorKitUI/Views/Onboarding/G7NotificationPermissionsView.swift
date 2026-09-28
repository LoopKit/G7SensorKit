//
//  G7NotificationPermissionsView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import SwiftUI
import UserNotifications

/// What the phone will let Loop's alerts do: notify at all, break through
/// Silent mode and Focus as Critical Alerts, or at least as Time Sensitive
/// ones. `criticalAlerts == .notSupported` is how a build without Apple's
/// Critical Alerts entitlement shows up, which is the case that needs the
/// most advice.
struct G7NotificationStatus: Equatable {
    var authorized: Bool
    var criticalAlerts: UNNotificationSetting
    var timeSensitive: UNNotificationSetting

    static func fetch(_ completion: @escaping (G7NotificationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = G7NotificationStatus(
                authorized: settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional,
                criticalAlerts: settings.criticalAlertSetting,
                timeSensitive: settings.timeSensitiveSetting
            )
            DispatchQueue.main.async { completion(status) }
        }
    }
}

/// Shown after `G7AlertsFromLoopView`: checks the notification settings that
/// decide whether those alerts will actually be heard, and says what to
/// change. Re-checks whenever the app comes back from Settings.
struct G7NotificationPermissionsView: View {
    var didContinue: () -> Void

    @Environment(\.appName) private var appName
    @Environment(\.guidanceColors) private var guidanceColors

    @State private var status: G7NotificationStatus?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.largeTitle)
                        .foregroundColor(.accentColor)
                    Text(LocalizedString("Make Sure Alerts Reach You", comment: "Title of the notification permissions page shown when moving to a direct connection"))
                        .font(.title2)
                        .fontWeight(.semibold)
                }

                Text(String(format: LocalizedString("An alert is only useful if your phone lets it through. Here is how %1$@ stands right now.", comment: "First paragraph of the notification permissions page (1: appName)"), appName))
                    .fixedSize(horizontal: false, vertical: true)

                if let status = status {
                    statusRows(status)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if status.map(needsSettings) ?? false {
                    Button(action: openSettings) {
                        Text(LocalizedString("Open Settings", comment: "Button title to open the iOS Settings app"))
                            .actionButtonStyle(.secondary)
                    }
                }
                Button(action: didContinue) {
                    Text(LocalizedString("Continue", comment: "Button title to continue"))
                        .actionButtonStyle(.primary)
                }
            }
            .padding()
            .background(Color(.systemBackground))
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in refresh() }
    }

    @ViewBuilder
    private func statusRows(_ status: G7NotificationStatus) -> some View {
        row(
            ok: status.authorized,
            title: LocalizedString("Notifications", comment: "Status row title: notification permission"),
            detail: status.authorized
                ? LocalizedString("Allowed.", comment: "Status row detail: notifications allowed")
                : String(format: LocalizedString("Turned off. Allow notifications for %1$@ in Settings, or no alert will appear at all.", comment: "Status row detail: notifications denied (1: appName)"), appName)
        )

        switch status.criticalAlerts {
        case .enabled:
            row(
                ok: true,
                title: LocalizedString("Critical Alerts", comment: "Status row title: critical alerts"),
                detail: LocalizedString("On. Urgent alerts will sound even when your phone is silenced or in a Focus.", comment: "Status row detail: critical alerts enabled")
            )
        case .disabled:
            row(
                ok: false,
                title: LocalizedString("Critical Alerts", comment: "Status row title: critical alerts"),
                detail: String(format: LocalizedString("Turned off. Turn on Critical Alerts for %1$@ in Settings so urgent alerts sound through Silent mode and Focus.", comment: "Status row detail: critical alerts disabled (1: appName)"), appName)
            )
        default:
            row(
                ok: false,
                title: LocalizedString("Critical Alerts", comment: "Status row title: critical alerts"),
                detail: String(format: LocalizedString("Not available. This build of %1$@ does not have Apple's Critical Alerts entitlement, so its alerts cannot override Silent mode or a Focus on their own. To make sure they still get through:", comment: "Status row detail: critical alerts not supported (1: appName)"), appName),
                bullets: [
                    String(format: LocalizedString("In Settings › Notifications › %1$@, turn on Time Sensitive Notifications.", comment: "Advice bullet: time sensitive setting (1: appName)"), appName),
                    String(format: LocalizedString("In Settings › Focus, open each Focus you use and add %1$@ to its allowed apps.", comment: "Advice bullet: focus allowed apps (1: appName)"), appName),
                    LocalizedString("Keep your ringer on. Silent mode mutes every sound that is not a Critical Alert.", comment: "Advice bullet: ringer"),
                ]
            )
            if status.timeSensitive == .disabled {
                row(
                    ok: false,
                    title: LocalizedString("Time Sensitive Notifications", comment: "Status row title: time sensitive notifications"),
                    detail: String(format: LocalizedString("Turned off for %1$@. These are what let an alert break through a Focus without Critical Alerts.", comment: "Status row detail: time sensitive disabled (1: appName)"), appName)
                )
            }
        }
    }

    private func row(ok: Bool, title: String, detail: String, bullets: [String] = []) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundColor(ok ? guidanceColors.acceptable : guidanceColors.warning)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                        Text(bullet)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
                }
            }
        }
    }

    private func needsSettings(_ status: G7NotificationStatus) -> Bool {
        !status.authorized || status.criticalAlerts != .enabled || status.timeSensitive == .disabled
    }

    private func refresh() {
        G7NotificationStatus.fetch { status = $0 }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
