//
//  G7DexcomApp.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import UIKit

/// The Dexcom apps that can hold a G7-family sensor's display slot: the G7
/// app, the ONE+ app and the Stelo app.
///
/// Relevant in both directions. An eavesdropping session cannot work without
/// one of them. A direct session cannot work reliably with one installed: a
/// sensor admits one display, and the Dexcom app will keep trying to be it.
///
/// Detection is by URL scheme, the only means iOS offers, and only works for
/// schemes the host app lists under `LSApplicationQueriesSchemes` (Loop
/// lists all of these); otherwise `canOpenURL` answers false for everything
/// and the app is reported absent. All three schemes are confirmed against
/// the apps (G7 and Stelo by probe on a phone with both installed,
/// 2026-09-15; ONE+ from its app). `describeProbe()` logs what answered,
/// which is how a new scheme would be settled if Dexcom ever changes one.
enum G7DexcomApp: CaseIterable {
    case g7
    case onePlus
    case stelo

    var displayName: String {
        switch self {
        case .g7: return "Dexcom G7"
        case .onePlus: return "Dexcom ONE+"
        case .stelo: return "Stelo"
        }
    }

    /// The scheme each app registers. A list, so a renamed scheme can be
    /// carried alongside the old one for a release.
    var schemes: [String] {
        switch self {
        case .g7: return ["dexcomg7"]
        case .onePlus: return ["dexcomoneplus"]
        case .stelo: return ["stelo"]
        }
    }

    /// The scheme the phone answers for, if any.
    var installedScheme: String? {
        schemes.first { scheme in
            URL(string: scheme + "://").map(UIApplication.shared.canOpenURL) ?? false
        }
    }

    var isInstalled: Bool {
        installedScheme != nil
    }

    /// Every Dexcom app found on this phone.
    static var installedApps: [G7DexcomApp] {
        allCases.filter(\.isInstalled)
    }

    static var isAnyInstalled: Bool {
        !installedApps.isEmpty
    }

    /// "Dexcom G7", "Dexcom G7 and Stelo", for the warnings that name what
    /// has to be deleted. Falls back to a generic name if nothing is found,
    /// for callers that show the warning on other grounds.
    static var installedAppNames: String {
        let names = installedApps.map(\.displayName)
        switch names.count {
        case 0: return "Dexcom"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " " + LocalizedString("and", comment: "Conjunction between the last two app names in a list") + " " + names.last!
        }
    }

    /// The G7 app, kept for the settings button that opens it.
    static var isInstalled: Bool {
        isAnyInstalled
    }

    static let url = URL(string: "dexcomg7://")!

    /// Opens whichever Dexcom app is installed, preferring the G7 app.
    static func open() {
        let scheme = installedApps.first?.installedScheme ?? "dexcomg7"
        if let url = URL(string: scheme + "://") {
            UIApplication.shared.open(url)
        }
    }

    /// A one-line account of every probe, for the device log: which schemes
    /// answered and which did not.
    static func describeProbe() -> String {
        allCases.map { app in
            let answered = app.schemes.map { scheme in
                let ok = URL(string: scheme + "://").map(UIApplication.shared.canOpenURL) ?? false
                return "\(scheme)=\(ok ? "yes" : "no")"
            }
            return "\(app.displayName): " + answered.joined(separator: " ")
        }.joined(separator: "; ")
    }
}
