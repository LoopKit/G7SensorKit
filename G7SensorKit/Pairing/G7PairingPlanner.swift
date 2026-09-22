//
//  G7PairingPlanner.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//
//  Derived from DexKit by Erik Tolboom (https://github.com/nightscout/DexKit):
//  candidate planning follows its G7PairingRunner.
//

import Foundation

/// Decides which sensor to try next, and when to stop.
///
/// A pairing code does not identify a sensor over the air (the advertised
/// name suffix is unrelated to it), so pairing may have to try several
/// sensors in range. The order matters: a sensor whose display slot is held
/// by another phone will reject us, and four rejections in a row make a
/// sensor stop accepting connections for a while. So unheld sensors go
/// first, and within a class the strongest signal goes first — the sensor
/// being paired is in the user's hand, so it is almost always the nearest
/// one. A sensor that rejects us is dropped rather than retried, and
/// ordinary failures (a dropped link, a timeout) get a bounded number of
/// retries before moving on.
///
/// Pure bookkeeping with no Bluetooth of its own, so the policy is testable
/// in isolation.
struct G7PairingPlanner {

    /// RSSI stand-in for an advertisement whose signal strength is unknown
    /// (CoreBluetooth reports 127 when it cannot be read). Sorts weakest, so
    /// candidates with a real reading are preferred, and equal-signal ties —
    /// including every candidate when no signal is known — fall back to the
    /// order already established.
    static let unknownRSSI = Int.min

    struct Candidate: Equatable {
        let id: UUID
        let name: String
        var isPhoneSlotHeld: Bool
        var rssi: Int
    }

    enum Action: Equatable {
        /// Try the current candidate again.
        case retryCurrent
        /// Move on to the next candidate.
        case advanceToNext
        /// Every sensor discovered so far has been tried, but the scan is
        /// still open: keep looking for the one the code belongs to.
        case keepScanning
        /// Nothing left to try.
        case giveUp(reason: String)
    }

    /// Ordinary failures tolerated per candidate before moving on.
    static let attemptsPerCandidate = 3

    /// When the discovered candidates are exhausted, whether to keep scanning
    /// for more rather than giving up. Manual code entry cannot tell the
    /// intended sensor from a neighbour, so a sensor that does not match the
    /// code is only a wrong guess, not a wrong code — the real one may not
    /// have advertised yet. A scan (serial known) has already filtered to the
    /// one sensor, so a mismatch there is a wrong code and stops.
    let keepScanningWhenExhausted: Bool

    private(set) var candidates: [Candidate] = []
    private(set) var currentIndex = 0
    private var attemptsOnCurrent = 0

    /// Why candidates were dropped, for the failure message if nothing works.
    private(set) var abandonmentReasons: [String] = []

    init(keepScanningWhenExhausted: Bool = false) {
        self.keepScanningWhenExhausted = keepScanningWhenExhausted
    }

    var currentCandidate: Candidate? {
        currentIndex < candidates.count ? candidates[currentIndex] : nil
    }

    /// The attempt number the next try will be, 1-based.
    var nextAttemptNumber: Int {
        attemptsOnCurrent + 1
    }

    /// The message to show if the scan is stopped with nothing paired.
    var exhaustionReason: String {
        if candidates.isEmpty {
            return LocalizedString(
                "No sensor was found. Make sure the sensor is inserted and within range.",
                comment: "Pairing failure reason when no G7 sensor was discovered"
            )
        }
        if !abandonmentReasons.isEmpty {
            return abandonmentReasons.joined(separator: "\n")
        }
        return LocalizedString(
            "Could not pair with any sensor in range.",
            comment: "Pairing failure reason when every discovered G7 sensor failed"
        )
    }

    /// Adds a newly discovered sensor. Returns false if it was already known.
    ///
    /// New candidates are ordered behind anything already tried, then by
    /// class (unheld before held, since held ones are likely to reject us)
    /// and by signal strength within a class.
    @discardableResult
    mutating func addCandidate(id: UUID, name: String, isPhoneSlotHeld: Bool, rssi: Int = unknownRSSI) -> Bool {
        guard !candidates.contains(where: { $0.id == id }) else {
            return false
        }
        candidates.append(Candidate(id: id, name: name, isPhoneSlotHeld: isPhoneSlotHeld, rssi: rssi))
        sortUntriedTail()
        return true
    }

    /// Records a fresh advertisement from a known candidate. A held slot
    /// frees up after ~15 minutes of silence, so a candidate deferred earlier
    /// can become preferable; a new signal reading can reorder it too.
    /// Returns whether anything changed. A `nil` slot state or an
    /// `unknownRSSI` reading leaves that stored value alone.
    @discardableResult
    mutating func updateSlot(id: UUID, isPhoneSlotHeld: Bool?, rssi: Int = unknownRSSI) -> Bool {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else {
            return false
        }
        var changed = false
        if let isPhoneSlotHeld = isPhoneSlotHeld, candidates[index].isPhoneSlotHeld != isPhoneSlotHeld {
            candidates[index].isPhoneSlotHeld = isPhoneSlotHeld
            changed = true
        }
        if rssi != G7PairingPlanner.unknownRSSI, candidates[index].rssi != rssi {
            candidates[index].rssi = rssi
            changed = true
        }
        guard changed else {
            return false
        }
        sortUntriedTail()
        return true
    }

    /// Orders the untried tail: unheld before held, then strongest signal,
    /// then the order already established (a stable sort, so equal readings —
    /// and unknown ones — keep their place). Never touches the current
    /// candidate or anything before it: the current one may be mid-handshake.
    private mutating func sortUntriedTail() {
        let tailStart = currentIndex + 1
        guard tailStart < candidates.count else {
            return
        }
        let ordered = candidates[tailStart...].enumerated().sorted { lhs, rhs in
            if lhs.element.isPhoneSlotHeld != rhs.element.isPhoneSlotHeld {
                return !lhs.element.isPhoneSlotHeld
            }
            if lhs.element.rssi != rhs.element.rssi {
                return lhs.element.rssi > rhs.element.rssi
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        candidates.replaceSubrange(tailStart..., with: ordered)
    }

    /// An ordinary failure on the current candidate: retry it, or move on if
    /// it has used up its attempts.
    mutating func recordFailure() -> Action {
        guard currentCandidate != nil else {
            return exhausted()
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
            return exhausted()
        }
        abandonmentReasons.append("\(candidate.name): \(reason)")
        return advance()
    }

    private mutating func advance() -> Action {
        currentIndex += 1
        attemptsOnCurrent = 0
        return currentCandidate != nil ? .advanceToNext : exhausted()
    }

    private func exhausted() -> Action {
        keepScanningWhenExhausted ? .keepScanning : .giveUp(reason: exhaustionReason)
    }
}
