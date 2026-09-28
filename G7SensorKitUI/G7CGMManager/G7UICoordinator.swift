//
//  G7UICoordinator.swift
//  CGMBLEKitUI
//
//  Created by Pete Schwamb on 9/24/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKitUI
import G7SensorKit
import SwiftUI

private enum G7Screen {
    case startup
    /// Shown ahead of everything else whenever the Dexcom G7 app is installed.
    case dexcomAppWarning
    /// Placement and application guidance. Only for a sensor that is not on
    /// yet; an eavesdropping session moving to direct already has one on.
    case applySensor
    /// For an eavesdropping session moving to direct: the alerts the Dexcom
    /// app used to raise now have to come from Loop, and the phone has to
    /// let them through.
    case alertsFromLoop
    case notificationPermissions
    /// Scan the applicator, or choose to type the code instead. Skipped
    /// where there is no scanner to offer.
    case scanCode
    case enterCode
    case pairing(code: String, serial: String?)
    case pairingSuccess(deviceName: String?)
    /// Optional Dexcom Share sign-in at the end of first-time setup.
    case shareSignIn
    case settings
}

class G7UICoordinator: UINavigationController, CGMManagerOnboarding, CompletionNotifying, UINavigationControllerDelegate {
    var cgmManagerOnboardingDelegate: LoopKitUI.CGMManagerOnboardingDelegate?
    var completionDelegate: LoopKitUI.CompletionDelegate?
    var cgmManager: G7CGMManager?
    var displayGlucosePreference: DisplayGlucosePreference

    var colorPalette: LoopUIColorPalette

    private let isInitialSetup: Bool
    private var screenStack = [G7Screen]()

    /// Whether the pairing flow in progress is for a sensor not yet applied.
    private var isPairingNewSensor = true

    init(cgmManager: G7CGMManager? = nil,
         colorPalette: LoopUIColorPalette,
         displayGlucosePreference: DisplayGlucosePreference,
         allowDebugFeatures: Bool)
    {
        self.cgmManager = cgmManager
        self.isInitialSetup = cgmManager == nil
        self.colorPalette = colorPalette
        self.displayGlucosePreference = displayGlucosePreference
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        delegate = self

        navigationBar.prefersLargeTitles = true // Ensure nav bar text is displayed correctly

        let start: G7Screen = isInitialSetup ? .startup : .settings
        screenStack = [start]
        setViewControllers([viewController(for: start)], animated: false)
    }

    private func hostingController<Content: View>(_ content: Content, largeTitle: Bool = true) -> UIViewController {
        let hostingController = DismissibleHostingController(
            content: content.environment(\.appName, Bundle.main.bundleDisplayName),
            colorPalette: colorPalette
        )
        hostingController.navigationItem.largeTitleDisplayMode = largeTitle ? .automatic : .never
        return hostingController
    }

    /// Whether the sensor being paired is the one an eavesdropping session
    /// has been reading through the Dexcom app.
    private var isReplacingDexcomAppSession: Bool {
        !isPairingNewSensor && cgmManager?.sessionMode == .eavesdropping
    }

    /// The navigation bar title for each pushed screen.
    ///
    /// Set on the controller rather than left to the SwiftUI views. A hosted
    /// view's `navigationBarTitle` does reach its navigation item, but the bar
    /// came up empty in the app anyway, and a title set here cannot be lost on
    /// the way. Startup is deliberately untitled: it carries its own large
    /// title in the content.
    private func title(for screen: G7Screen) -> String? {
        switch screen {
        case .startup:
            return nil
        case .dexcomAppWarning:
            return LocalizedString("Before You Pair", comment: "Navigation title of the Dexcom app warning screen")
        case .applySensor:
            return LocalizedString("New Sensor", comment: "Navigation title of the apply-sensor screen")
        case .alertsFromLoop:
            return LocalizedString("Alerts", comment: "Navigation title of the alerts hand-off page")
        case .notificationPermissions:
            return LocalizedString("Notifications", comment: "Navigation title of the notification permissions page")
        case .scanCode:
            return LocalizedString("Pairing Code", comment: "Navigation title of the pairing code entry screen")
        case .enterCode:
            return LocalizedString("Enter Code", comment: "Navigation title of the screen where the pairing code is typed")
        case .pairing:
            return LocalizedString("Pairing", comment: "Navigation title of the pairing progress screen")
        case .pairingSuccess:
            return LocalizedString("Paired", comment: "Navigation title of the pairing success screen")
        case .shareSignIn:
            return LocalizedString("Dexcom Share", comment: "Navigation title of the Share sign-in page")
        case .settings:
            return cgmManager?.localizedTitle
        }
    }

    private func viewController(for screen: G7Screen) -> UIViewController {
        let controller = makeViewController(for: screen)
        controller.title = title(for: screen)
        return controller
    }

    private func makeViewController(for screen: G7Screen) -> UIViewController {
        switch screen {
        case .startup:
            let view = G7StartupView(
                didChoosePairing: { [weak self] in self?.beginPairingFlow(newSensor: true) },
                didChooseDexcomApp: { [weak self] in self?.completeLegacySetup() },
                didCancel: { [weak self] in
                    if let self = self {
                        self.completionDelegate?.completionNotifyingDidComplete(self)
                    }
                }
            )
            return hostingController(view, largeTitle: false)

        case .dexcomAppWarning:
            let view = G7DexcomAppWarningView(
                isReplacingDexcomAppSession: isReplacingDexcomAppSession,
                isDexcomAppInstalled: { G7DexcomApp.isAnyInstalled },
                didContinue: { [weak self] in self?.continueAfterDexcomAppCheck() }
            )
            return hostingController(view, largeTitle: false)

        case .applySensor:
            let view = G7ApplySensorView { [weak self] in self?.navigateToCodeEntry() }
            return hostingController(view, largeTitle: false)

        case .alertsFromLoop:
            let view = G7AlertsFromLoopView { [weak self] in self?.navigate(to: .notificationPermissions) }
            return hostingController(view, largeTitle: false)

        case .notificationPermissions:
            let view = G7NotificationPermissionsView { [weak self] in self?.navigateToCodeEntry() }
            return hostingController(view, largeTitle: false)

        case .scanCode:
            let view = G7ScanCodeView(
                didScanCode: { [weak self] code, serial in
                    self?.navigate(to: .pairing(code: code, serial: serial))
                },
                didChooseManualEntry: { [weak self] in self?.navigate(to: .enterCode) }
            )
            return hostingController(view, largeTitle: false)

        case .enterCode:
            let view = G7EnterCodeView { [weak self] code in
                self?.navigate(to: .pairing(code: code, serial: nil))
            }
            return hostingController(view, largeTitle: false)

        case .pairing(let code, let serial):
            let viewModel = G7PairingViewModel(
                pairingCode: code,
                serial: serial,
                cgmManager: cgmManager,
                onLog: { [weak self] message in
                    self?.recordPairingLog(message)
                },
                onSuccess: { [weak self] peripheralIdentifier, sharedKey, deviceName, handoff in
                    self?.pairingSucceeded(
                        code: code,
                        peripheralIdentifier: peripheralIdentifier,
                        sharedKey: sharedKey,
                        deviceName: deviceName,
                        handoff: handoff
                    )
                }
            )
            let view = G7PairingView(viewModel: viewModel, didEditCode: { [weak self] in self?.popScreen() })
            return hostingController(view, largeTitle: false)

        case .pairingSuccess(let deviceName):
            let offersShare = isInitialSetup && cgmManager?.shareAccount == nil
            // The product to picture comes from the name the sensor
            // advertised; `.g7` when it did not announce one, matching what
            // the pairing screen showed a moment ago.
            let model = deviceName.flatMap(G7SensorModel.init(advertisedName:)) ?? .g7
            let view = G7PairingSuccessView(model: model, deviceName: deviceName, hasNextStep: offersShare) { [weak self] in
                guard let self = self else { return }
                if offersShare {
                    self.navigate(to: .shareSignIn)
                } else {
                    self.finishPairingFlow()
                }
            }
            return hostingController(view, largeTitle: false)

        case .shareSignIn:
            let view = G7ShareSignInView(
                signIn: { [weak self] credentials in
                    guard let manager = self?.cgmManager else { throw G7ShareError.notSignedIn }
                    try await manager.signInToShare(credentials)
                },
                didFinish: { [weak self] in self?.finishPairingFlow() },
                didSkip: { [weak self] in self?.finishPairingFlow() }
            )
            return hostingController(view, largeTitle: false)

        case .settings:
            let view = G7SettingsView(
                didFinish: { [weak self] in
                    if let self = self {
                        self.completionDelegate?.completionNotifyingDidComplete(self)
                    }
                },
                deleteCGM: { [ weak self] in
                    // `delete`, not `notifyDelegateOfDeletion`: the manager's
                    // own teardown retracts its standing alerts first, and Loop
                    // replays anything left behind at every launch.
                    self?.cgmManager?.delete {
                        DispatchQueue.main.async {
                            if let self = self {
                                self.completionDelegate?.completionNotifyingDidComplete(self)
                                self.dismiss(animated: true)
                            }
                        }
                    }
                },
                pairNewSensor: { [weak self] in self?.beginPairingFlow(newSensor: true) },
                pairCurrentSensor: { [weak self] in self?.beginPairingFlow(newSensor: false) },
                viewModel: G7SettingsViewModel(cgmManager: cgmManager!, displayGlucosePreference: displayGlucosePreference)
            )
            return hostingController(view)
        }
    }

    // MARK: - Flows

    /// - Parameter newSensor: whether the sensor still has to be applied.
    ///   An eavesdropping session moving to direct pairs the sensor already
    ///   on the arm, so it skips the application guide.
    private func beginPairingFlow(newSensor: Bool) {
        isPairingNewSensor = newSensor
        if cgmManager == nil {
            // The CGM exists from here on, paired or not: its device log
            // carries the pairing, and a run that does not finish can be
            // picked up again from settings.
            let manager = G7CGMManager(sessionMode: .direct)
            cgmManager = manager
            cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: manager)
            cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: manager)
        }
        if G7DexcomApp.isAnyInstalled {
            navigate(to: .dexcomAppWarning)
        } else {
            continueAfterDexcomAppCheck()
        }
    }

    private func continueAfterDexcomAppCheck() {
        if isPairingNewSensor {
            navigate(to: .applySensor)
        } else if isReplacingDexcomAppSession {
            navigate(to: .alertsFromLoop)
        } else {
            navigateToCodeEntry()
        }
    }

    /// Asks for the pairing code, by way of the scan where there is a scanner
    /// to offer. Without one there is nothing to choose between, so that
    /// screen is skipped rather than shown with one way out.
    private func navigateToCodeEntry() {
        // `isSupported`, not `isAvailable`: a camera that is momentarily busy
        // frees up again, and routing on that would strand someone on the
        // typing screen with no way back to the scan.
        navigate(to: G7PackageScannerView.isSupported ? .scanCode : .enterCode)
    }

    /// The pre-pairing setup, kept for someone who cannot pair the sensor
    /// they are already wearing.
    private func completeLegacySetup() {
        let manager = G7CGMManager()
        cgmManager = manager
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: manager)
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: manager)
        completionDelegate?.completionNotifyingDidComplete(self)
    }

    private func recordPairingLog(_ message: String) {
        cgmManager?.logDeviceCommunication("[pairing] " + message, type: .connection)
    }

    private func pairingSucceeded(code: String, peripheralIdentifier: UUID, sharedKey: Data, deviceName: String?, handoff: G7PairingHandoff?) {
        cgmManager?.applyPairingResult(pairingCode: code, peripheralIdentifier: peripheralIdentifier, sharedKey: sharedKey, handoff: handoff)
        navigate(to: .pairingSuccess(deviceName: deviceName))
    }

    private func finishPairingFlow() {
        if isInitialSetup {
            completionDelegate?.completionNotifyingDidComplete(self)
        } else {
            // Back to settings, which observes the manager and already shows
            // the new session.
            screenStack = [.settings]
            popToRootViewController(animated: true)
        }
    }

    // MARK: - Navigation

    private func navigate(to screen: G7Screen) {
        screenStack.append(screen)
        pushViewController(viewController(for: screen), animated: true)
    }

    private func popScreen() {
        if !screenStack.isEmpty {
            screenStack.removeLast()
        }
        popViewController(animated: true)
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        // Keep the stack honest when the user pops with the back button.
        let shown = navigationController.viewControllers.count
        if screenStack.count > shown {
            screenStack.removeLast(screenStack.count - shown)
        }
        // Resume the session if pairing was abandoned from settings.
        if !isInitialSetup, shown == 1 {
            cgmManager?.sensor.resumeScanning()
        }
    }
}
