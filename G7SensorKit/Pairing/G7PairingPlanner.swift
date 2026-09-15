//
//  G7PairingPlanner.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  Derived from DexKit by Erik Tolboom (https://github.com/nightscout/DexKit):
//  candidate planning follows its G7PairingPlanner.
//

import Foundation

/// Decides which sensor to try next, and when to stop.
///
/// A pairing code does not identify a sensor over the air (the advertised
/// name suffix is unrelated to it), so pairing may have to try several
/// sensors in range. The order matters: a sensor whose display slot is held
/// by another phone will reject us, and four rejections in a row make a
/// sensor stop accepting connections for a while. So unheld sensors go
/// first, a sensor that rejects us is dropped rather than retried, and
/// ordinary failures (a dropped link, a timeout) get a bounded number of
/// retries before moving on.
///
/// Pure bookkeeping with no Bluetooth of its own, so the policy is testable
/// in isolation.
struct G7PairingPlanner {

    struct Candidate: Equatable {
        let id: UUID
        let name: String
        var isPhoneSlotHeld: Bool
    }

    enum Action: Equatable {
        /// Try the current candidate again.
        case retryCurrent
        /// Move on to the next candidate.
        case advanceToNext
        /// Nothing left to try.
        case giveUp(reason: String)
    }

    /// Ordinary failures tolerated per candidate before moving on.
    static let attemptsPerCandidate = 3

    private(set) var candidates: [Candidate] = []
    private(set) var currentIndex = 0
    private var attemptsOnCurrent = 0

    /// Why candidates were dropped, for the failure message if nothing works.
    private(set) var abandonmentReasons: [String] = []

    var currentCandidate: Candidate? {
        currentIndex < candidates.count ? candidates[currentIndex] : nil
    }

    /// The attempt number the next try will be, 1-based.
    var nextAttemptNumber: Int {
        attemptsOnCurrent + 1
    }

    /// Adds a newly discovered sensor. Returns false if it was already known.
    ///
    /// New candidates go behind everything already tried, and behind
    /// untried candidates of a better class: an unheld newcomer is queued
    /// ahead of untried held candidates, since those are likely to reject us.
    @discardableResult
    mutating func addCandidate(id: UUID, name: String, isPhoneSlotHeld: Bool) -> Bool {
        guard !candidates.contains(where: { $0.id == id }) else {
            return false
        }
        let candidate = Candidate(id: id, name: name, isPhoneSlotHeld: isPhoneSlotHeld)

        // Never reorder anything at or before the current index: the current
        // candidate may be mid-handshake.
        let untried = candidates.indices.filter { $0 > currentIndex }
        if !isPhoneSlotHeld, let firstHeld = untried.first(where: { candidates[$0].isPhoneSlotHeld }) {
            candidates.insert(candidate, at: firstHeld)
        } else {
            candidates.append(candidate)
        }
        return true
    }

    /// Records a fresh advertisement from a known candidate. A held slot
    /// frees up after ~15 minutes of silence, so a candidate deferred earlier
    /// can become preferable. Returns whether anything changed.
    @discardableResult
    mutating func updateSlot(id: UUID, isPhoneSlotHeld: Bool) -> Bool {
        guard let index = candidates.firstIndex(where: { $0.id == id }),
              candidates[index].isPhoneSlotHeld != isPhoneSlotHeld
        else {
            return false
        }
        candidates[index].isPhoneSlotHeld = isPhoneSlotHeld

        // Re-sort only the untried tail, preserving discovery order within
        // each class.
        let tailStart = currentIndex + 1
        guard tailStart < candidates.count else {
            return true
        }
        let tail = candidates[tailStart...]
        candidates.replaceSubrange(tailStart..., with: tail.filter { !$0.isPhoneSlotHeld } + tail.filter { $0.isPhoneSlotHeld })
        return true
    }

    /// An ordinary failure on the current candidate: retry it, or move on if
    /// it has used up its attempts.
    mutating func recordFailure() -> Action {
        guard currentCandidate != nil else {
            return giveUp()
        }
        attemptsOnCurrent += 1
        if attemptsOnCurrent < G7PairingPlanner.attemptsPerCandidate {
            return .retryCurrent
        }
        return advance()
    }

    /// The current candidate cannot succeed (it rejected us, or it proved it
    /// does not belong to this code): drop it without retrying.
    mutating func abandonCurrentCandidate(reason: String) -> Action {
        guard let candidate = currentCandidate else {
            return giveUp()
        }
        abandonmentReasons.append("\(candidate.name): \(reason)")
        return advance()
    }

    private mutating func advance() -> Action {
        currentIndex += 1
        attemptsOnCurrent = 0
        return currentCandidate != nil ? .advanceToNext : giveUp()
    }

    private func giveUp() -> Action {
        if candidates.isEmpty {
            return .giveUp(reason: LocalizedString(
                "No sensor was found. Make sure the sensor is inserted and within range.",
                comment: "Pairing failure reason when no G7 sensor was discovered"
            ))
        }
        if !abandonmentReasons.isEmpty {
            return .giveUp(reason: abandonmentReasons.joined(separator: "\n"))
        }
        return .giveUp(reason: LocalizedString(
            "Could not pair with any sensor in range.",
            comment: "Pairing failure reason when every discovered G7 sensor failed"
        ))
    }
}
