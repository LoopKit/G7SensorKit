//
//  AuthChallengeRxMessage.swift
//  xDrip5
//
//  Created by Nathan Racklyeft on 11/22/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import Foundation

/// Why a sensor refused an authenticated connection: byte 2 of a `05 02 xx`
/// verdict. (On success that byte is the bond state instead.)
public enum G7AuthFailureCode: UInt8 {
    case none = 0
    /// Our key is not the one the sensor holds for this display.
    case challengeMismatch = 1
    /// Another display of our type holds the sensor's slot.
    case deviceTypeRestriction = 2
    /// The sensor no longer has a key for us at all. Recoverable without the
    /// user: a fresh key exchange with the retained pairing code.
    case noAppKey = 3
}

/// The sensor's verdict on the AES challenge: `05 <authStatus> <bondStatus>`,
/// delivered on the authentication characteristic.
struct AuthChallengeRxMessage: SensorMessage {
    let authStatus: UInt8
    let bondStatus: UInt8

    var isAuthenticated: Bool {
        authStatus == 0x1
    }

    var isBonded: Bool {
        bondStatus == 0x1
    }

    /// The sensor verified our key and still refused the session. Terminal:
    /// the cause is external (another display holds the sensor's single slot,
    /// or the code belongs to a different sensor), so a retry cannot succeed,
    /// and four refusals in a row put the sensor into a cooldown where it
    /// stops accepting connections at all.
    ///
    /// Any other non-authenticated status means the handshake simply is not
    /// finished, and the certificate exchange follows.
    var isRejected: Bool {
        authStatus == 0x2
    }

    /// The sensor's reason for a rejection; nil when not rejected or when the
    /// byte is one we have no name for.
    var failureCode: G7AuthFailureCode? {
        guard isRejected else {
            return nil
        }
        return G7AuthFailureCode(rawValue: bondStatus)
    }

    init?(data: Data) {
        guard data.count >= 3 else {
            return nil
        }

        guard data.starts(with: .authChallengeRx) else {
            return nil
        }

        authStatus = data[data.startIndex + 1]
        bondStatus = data[data.startIndex + 2]
    }
}
