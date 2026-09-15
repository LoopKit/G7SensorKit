//
//  G7ApplySensorView.swift
//  G7SensorKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  The application steps and their images are from DexKit by Erik Tolboom
//  (https://github.com/nightscout/DexKit).
//

import SwiftUI

/// One illustrated step of putting on a sensor.
struct G7ApplyStep: Identifiable {
    let id: Int
    let title: String
    let section: String
    let assetName: String
    let body: String
    let note: String?
}

/// The walkthrough, in the order the applicator box lays it out: insert the
/// sensor, then apply the overpatch.
enum G7ApplySteps {
    private static let insertSection = LocalizedString("INSERT SENSOR", comment: "Section label above the insert-sensor steps")
    private static let overpatchSection = LocalizedString("APPLY OVERPATCH", comment: "Section label above the overpatch steps")

    private static func insertTitle(_ number: Int) -> String {
        String(format: LocalizedString("Step %d of 7", comment: "Insert-sensor step counter (1: step number)"), number)
    }

    private static func overpatchTitle(_ letter: String) -> String {
        String(format: LocalizedString("Step 7%@ of 7", comment: "Overpatch step counter (1: letter A to E)"), letter)
    }

    static var all: [G7ApplyStep] {
        [
            G7ApplyStep(
                id: 1, title: insertTitle(1), section: insertSection, assetName: "G7SiteAdult",
                body: LocalizedString("Choose a site. Adults: the back of the upper arm. Ages 7 and up may also use the abdomen; ages 2 to 6 may also use the upper buttocks.", comment: "Apply step 1: choosing a site"),
                note: LocalizedString("Stay clear of loose skin, scars, tattoos, your waistband, and anywhere you inject insulin or wear a pump.", comment: "Apply step 1 note: sites to avoid")
            ),
            G7ApplyStep(
                id: 2, title: insertTitle(2), section: insertSection, assetName: "G7CleanDry",
                body: LocalizedString("Wash and dry your hands. Clean the site with an alcohol wipe and let it dry completely.", comment: "Apply step 2: clean the site"),
                note: LocalizedString("Adhesive will not hold on damp skin.", comment: "Apply step 2 note")
            ),
            G7ApplyStep(
                id: 3, title: insertTitle(3), section: insertSection, assetName: "G7UnscrewCap",
                body: LocalizedString("Hold the applicator by its narrow end and unscrew the wide cap.", comment: "Apply step 3: unscrew the cap"),
                note: LocalizedString("Do not use a damaged applicator, and keep fingers away from the needle end.", comment: "Apply step 3 note")
            ),
            G7ApplyStep(
                id: 4, title: insertTitle(4), section: insertSection, assetName: "G7InsertSensor",
                body: LocalizedString("Relax the muscles at the site. Press the applicator flat against your skin until the clear ring disappears, then press the button.", comment: "Apply step 4: insert the sensor"),
                note: nil
            ),
            G7ApplyStep(
                id: 5, title: insertTitle(5), section: insertSection, assetName: "G7RemoveApplicator",
                body: LocalizedString("Lift the applicator straight off. The sensor stays on your skin.", comment: "Apply step 5: remove the applicator"),
                note: LocalizedString("Keep the applicator until you have paired: the 4-digit pairing code is printed on it. Dispose of it as sharps afterwards.", comment: "Apply step 5 note: keep the applicator for its code")
            ),
            G7ApplyStep(
                id: 6, title: insertTitle(6), section: insertSection, assetName: "G7PushOn",
                body: LocalizedString("Hold the sensor down for 10 seconds, then rub firmly around the patch three times.", comment: "Apply step 6: secure the patch"),
                note: LocalizedString("Keeping the patch dry for the first 12 hours helps it last.", comment: "Apply step 6 note")
            ),
            G7ApplyStep(
                id: 7, title: overpatchTitle("A"), section: overpatchSection, assetName: "G7OverpatchA",
                body: LocalizedString("Peel off both clear liners, one at a time, without touching the white adhesive.", comment: "Overpatch step A"),
                note: nil
            ),
            G7ApplyStep(
                id: 8, title: overpatchTitle("B"), section: overpatchSection, assetName: "G7OverpatchB",
                body: LocalizedString("Holding the colored tab, center the overpatch over the sensor and press it on.", comment: "Overpatch step B"),
                note: nil
            ),
            G7ApplyStep(
                id: 9, title: overpatchTitle("C"), section: overpatchSection, assetName: "G7OverpatchC",
                body: LocalizedString("Rub all the way around the overpatch.", comment: "Overpatch step C"),
                note: nil
            ),
            G7ApplyStep(
                id: 10, title: overpatchTitle("D"), section: overpatchSection, assetName: "G7OverpatchD",
                body: LocalizedString("Pull the tab to remove the colored top liner, leaving the overpatch in place.", comment: "Overpatch step D"),
                note: nil
            ),
            G7ApplyStep(
                id: 11, title: overpatchTitle("E"), section: overpatchSection, assetName: "G7OverpatchE",
                body: LocalizedString("Rub around the overpatch once more.", comment: "Overpatch step E"),
                note: LocalizedString("That's it. Next, enter the pairing code from the applicator.", comment: "Overpatch step E note: pairing is next")
            )
        ]
    }
}

/// A walkthrough figure. Falls back to a symbol when the artwork is not in
/// the bundle, so a missing asset degrades to a plainer page rather than a
/// blank one.
struct G7StepFigure: View {
    let assetName: String
    var height: CGFloat = 220

    var body: some View {
        Group {
            if let image = UIImage(named: assetName, in: FrameworkBundle.main, compatibleWith: nil) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "sensor.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(.secondary)
                    .padding(40)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}

/// The screen before code entry for a new sensor: where it goes, what is in
/// the box, and a way into the step-by-step walkthrough.
struct G7ApplySensorView: View {
    var didContinue: () -> Void

    @Environment(\.appName) private var appName
    @State private var showingSteps = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    G7StepFigure(assetName: "G7InTheBox", height: 180)
                        .padding(.top, 16)

                    Text(LocalizedString("Apply the Sensor", comment: "Title of the apply-sensor screen"))
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(LocalizedString("Adults wear the sensor on the back of the upper arm. Children aged 2 to 17 can also use the abdomen or upper buttocks.", comment: "Apply-sensor screen: where the sensor goes"))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(LocalizedString("The box holds the applicator and an overpatch. The applicator inserts the sensor in one press; keep it afterwards, because the pairing code is printed on it.", comment: "Apply-sensor screen: box contents and the code"))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.accentColor)
                        Text(String(format: LocalizedString("You do not need the Dexcom app. Inserting the sensor starts its session on its own; pairing it with %1$@ on the next screen is all that is left to do.", comment: "Apply-sensor screen: the Dexcom app is not part of starting a sensor (1: appName)"), appName))
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(action: { showingSteps = true }) {
                        Label(LocalizedString("How to Apply a Sensor", comment: "Button title opening the step-by-step application guide"), systemImage: "questionmark.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
            }

            Button(action: didContinue) {
                Text(LocalizedString("Sensor Is On, Continue", comment: "Button title to proceed from the apply-sensor screen to code entry"))
                    .actionButtonStyle(.primary)
            }
            .padding()
        }
        .sheet(isPresented: $showingSteps) {
            G7ApplyStepsView(didFinish: { showingSteps = false })
        }
        .navigationBarTitle(Text(LocalizedString("New Sensor", comment: "Navigation title of the apply-sensor screen")), displayMode: .inline)
    }
}

/// The step-by-step walkthrough, one page per step.
struct G7ApplyStepsView: View {
    var didFinish: () -> Void

    private let steps = G7ApplySteps.all

    var body: some View {
        NavigationView {
            TabView {
                ForEach(steps) { step in
                    G7ApplyStepCard(step: step)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .navigationBarTitle(Text(LocalizedString("How to Apply a Sensor", comment: "Navigation title of the step-by-step application guide")), displayMode: .inline)
            .navigationBarItems(trailing: Button(LocalizedString("Done", comment: "Button title to finish setup"), action: didFinish))
        }
        .navigationViewStyle(.stack)
    }
}

struct G7ApplyStepCard: View {
    let step: G7ApplyStep

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                G7StepFigure(assetName: step.assetName)
                    .padding(.top, 8)

                Text(step.section)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Text(step.title)
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(step.body)
                    .fixedSize(horizontal: false, vertical: true)

                if let note = step.note {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.secondary)
                        Text(note)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding()
            .padding(.bottom, 40) // room for the page indicator
        }
    }
}
