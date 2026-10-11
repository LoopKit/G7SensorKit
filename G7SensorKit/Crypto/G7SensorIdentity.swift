//
//  G7SensorIdentity.swift
//  G7SensorKit
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import CryptoKit
import Foundation
import Security

/// Whether the sensor on the other end of a direct connection is a genuine
/// Dexcom sensor, the g7sim development emulator, or could not be verified.
///
/// A real G7 proves itself during pairing: it streams an X.509 P-256
/// certificate chain whose leaf is signed by Dexcom's sensor intermediate
/// `DEX01PG2`, and signs the display's key-challenge nonce with that leaf key
/// (ECDSA-P256 over SHA256(nonce)). The g7sim emulator mirrors this with its
/// own published CA, so the two are distinguishable. This is a safety marker —
/// it never blocks a connection, and `.unverified` is treated like a real
/// sensor (older sensors, or a capture we cannot parse, simply are not
/// flagged). The emulator's key is public, so `.simulated` only ever errs
/// toward "this is simulated data", never the reverse for a real sensor.
public enum G7SensorAuthenticity: String, Equatable {
    case genuine
    case simulated
    case unverified
}

enum G7SensorIdentity {

    /// Dexcom's sensor intermediate (`CN=DEX01PG2`), captured from a real G7 on
    /// 2026-10-10. A genuine sensor's leaf is signed by this.
    static let dexcomSensorAnchor = Data(hexadecimalString: [
        "308201e93082018fa00302010202145bb833870d8ff2cb8bfb33c39c1ba24f96",
        "c8b9cd300a06082a8648ce3d04030230133111300f06035504030c0844455830",
        "30504731301e170d3233303931333137323830355a170d333830393039313732",
        "3830355a30133111300f06035504030c0844455830315047323059301306072a",
        "8648ce3d020106082a8648ce3d0301070342000432959b9acf8602090669f3be",
        "8834790b9635ccf48bcc92e072c0bad63ba823cd5a84d4e9ea415d3ed64efabd",
        "b3a04f9c4ba723af4a751d020ce745700ad6c4a8a381c03081bd300f0603551d",
        "130101ff040530030101ff301f0603551d230418301680149e0f1e36f3f276a7",
        "01fe8e883a6e26a635bd6afc305a0603551d1f04533051304fa034a032863068",
        "7474703a2f2f63726c2e64702e736161732e7072696d656b65792e636f6d2f63",
        "726c2f44455830305047312e63726ca217a41530133111300f06035504030c08",
        "4445583030504731301d0603551d0e04160414d0d56feb7d94f4535aa0cadd41",
        "283536cb3aa2bf300e0603551d0f0101ff040403020186300a06082a8648ce3d",
        "0403020348003045022100d023f2223574705f40ab3d04a658a367392167c35c",
        "c22be4e7788c1de0c370350220532ef909c220944665bd9ac13cf0f4980d7b1f",
        "5bea1f2ca0de1c63be876ae566"
    ].joined())!

    /// The g7sim emulator's CA. Its signing key is public (a development
    /// marker), so this proves "simulated", not authenticity.
    static let emulatorAnchor = Data(hexadecimalString: [
        "308201573081fda003020102020101300a06082a8648ce3d0403023013311130",
        "0f06035504031308473753494d2d4341301e170d323630313031303030303030",
        "5a170d3436303130313030303030305a30133111300f06035504031308473753",
        "494d2d43413059301306072a8648ce3d020106082a8648ce3d03010703420004",
        "4ebb9d03cece8ddd5d96d6a350615ea4b6e4ca6817bee3bac0938fb9045da5a9",
        "cfda605269304703d2ebc1658d791be44831a3691dc27b3e83af202ed94ac673",
        "a3423040300e0603551d0f0101ff040403020284300f0603551d130101ff0405",
        "30030101ff301d0603551d0e0416041461e808e54c75334680ca4d6a2642a4c1",
        "3ed34aed300a06082a8648ce3d0403020349003046022100d432d52df4713636",
        "ecff04699d54cdce48946a0ed30dec1ab65dea4e22317b2c022100aecf28201b",
        "e53e58221a1623de554be8a2b5c71e9497a6177fb8c3edf4871027"
    ].joined())!

    /// Classifies a sensor from its leaf certificate, its 64-byte key-challenge
    /// signature (raw r‖s), and the nonce the display sent in the `0C` request.
    /// Never throws; anything it cannot verify is `.unverified`.
    static func authenticity(leafCertificate: Data, challengeSignature: Data, nonce: Data) -> G7SensorAuthenticity {
        guard challengeSignature.count == 64,
              let leaf = SecCertificateCreateWithData(nil, leafCertificate as CFData),
              let leafKey = SecCertificateCopyKey(leaf),
              let leafPublicKey = SecKeyCopyExternalRepresentation(leafKey, nil) as Data?,
              let publicKey = try? P256.Signing.PublicKey(x963Representation: leafPublicKey),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: challengeSignature)
        else {
            return .unverified
        }

        // The sensor must have signed our nonce with the leaf key: proof it
        // holds the private key of the certificate it presented.
        guard publicKey.isValidSignature(signature, for: nonce) else {
            return .unverified
        }

        if chains(leaf, toAnchor: dexcomSensorAnchor) {
            return .genuine
        }
        if chains(leaf, toAnchor: emulatorAnchor) {
            return .simulated
        }
        return .unverified
    }

    /// Whether `leaf` is signed by the single pinned `anchor` (used as the only
    /// trust anchor, so neither system roots nor the sensor's own streamed
    /// intermediate can substitute for it).
    private static func chains(_ leaf: SecCertificate, toAnchor anchorDER: Data) -> Bool {
        guard let anchor = SecCertificateCreateWithData(nil, anchorDER as CFData) else {
            return false
        }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates([leaf, anchor] as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust = trust
        else {
            return false
        }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        return SecTrustEvaluateWithError(trust, nil)
    }
}
