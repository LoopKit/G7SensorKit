//
//  G7SensorPackage.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// What the Data Matrix on a G7-family sensor applicator says.
///
/// The code is a GS1 element string. The parts pairing cares about are the
/// pairing code, carried in AI (240), and the sensor serial in AI (21), which
/// lets pairing skip sensors that cannot be this one. The GTIN in AI (01)
/// identifies the manufacturer.
public struct G7SensorPackage: Equatable {

    /// The leading digits of a Dexcom GTIN-14 as it appears in the barcode.
    static let dexcomCompanyPrefix = "0038627"

    public let gtin: String?
    public let serial: String?
    public let pairingCode: String?
    public let lot: String?
    public let expiry: String?

    /// Whether the GTIN says Dexcom made this.
    public var isDexcom: Bool {
        guard let gtin = gtin, gtin.count == 14 else {
            return false
        }
        return gtin.hasPrefix(G7SensorPackage.dexcomCompanyPrefix)
    }

    /// Parses a scanned Data Matrix payload. Returns nil when nothing useful
    /// was found, so a stray barcode is not mistaken for an applicator.
    public init?(dataMatrix payload: String) {
        let elements = GS1ElementString.parse(payload)
        gtin = elements["01"]
        serial = elements["21"]
        lot = elements["10"]
        expiry = elements["17"]

        // Only a four-digit value is a pairing code; anything else in the
        // field is some other product identifier.
        if let candidate = elements["240"], candidate.count == 4, candidate.allSatisfy(\.isNumber) {
            pairingCode = candidate
        } else {
            pairingCode = nil
        }

        guard gtin != nil || serial != nil || pairingCode != nil else {
            return nil
        }
    }
}

/// A minimal GS1 element-string parser: enough of the application identifier
/// table to read a sensor applicator.
///
/// Fixed-length AIs run straight into the next one; variable-length AIs end
/// at a group separator (FNC1, transmitted as ASCII 0x1D) or at the end of
/// the payload. Scanners sometimes prefix the payload with a symbology
/// identifier (`]d2`) or a leading FNC1, both of which are skipped.
enum GS1ElementString {

    /// Fixed-length application identifiers and their data lengths, per the
    /// GS1 General Specifications. Anything not listed is variable-length.
    private static let fixedLengths: [String: Int] = [
        "00": 18, "01": 14, "02": 14,
        "11": 6, "12": 6, "13": 6, "15": 6, "16": 6, "17": 6,
        "20": 2,
        "31": 8, "32": 8, "33": 8, "34": 8, "35": 8, "36": 8,
        "41": 15
    ]

    /// Application identifiers this parser knows, longest first so that
    /// "240" is matched before "24" could be mistaken for a prefix.
    private static let knownIdentifiers = ["240", "241", "242", "243", "250", "251", "253", "254", "255",
                                           "00", "01", "02", "10", "11", "12", "13", "15", "16", "17",
                                           "20", "21", "22", "30", "37", "90", "91", "92", "93", "94",
                                           "95", "96", "97", "98", "99"]

    private static let groupSeparator: Character = "\u{1D}"

    static func parse(_ payload: String) -> [String: String] {
        var input = Substring(payload)
        if input.hasPrefix("]d2") {
            input = input.dropFirst(3)
        }
        while input.first == groupSeparator {
            input = input.dropFirst()
        }

        var elements = [String: String]()
        while !input.isEmpty {
            guard let identifier = knownIdentifiers.first(where: { input.hasPrefix($0) }) else {
                // Unknown identifier: the rest cannot be framed reliably.
                break
            }
            input = input.dropFirst(identifier.count)

            let value: Substring
            if let length = fixedLengths[identifier] {
                value = input.prefix(length)
                input = input.dropFirst(length)
            } else if let separator = input.firstIndex(of: groupSeparator) {
                value = input[..<separator]
                input = input[input.index(after: separator)...]
            } else {
                value = input
                input = ""
            }

            // A fixed-length field may be followed by a separator some
            // encoders emit anyway.
            while input.first == groupSeparator {
                input = input.dropFirst()
            }

            if elements[identifier] == nil {
                elements[identifier] = String(value)
            }
        }
        return elements
    }
}
