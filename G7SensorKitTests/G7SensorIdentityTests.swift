//
//  G7SensorIdentityTests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import G7SensorKit

final class G7SensorIdentityTests: XCTestCase {

    // The real DXCMTR capture (2026-10-10): leaf cert, the 64-byte 0C block,
    // and the nonce the display sent.
    private let genuineLeaf = Data(hexadecimalString: [
            "308201a73082014da003020102021452c51b268669e8262757b9e482e226a2d5",
            "5903ff300a06082a8648ce3d04030230133111300f06035504030c0844455830",
            "31504732301e170d3235313031343036313133325a170d323731303134303631",
            "3133325a30323130302e06035504030c2730312c303030302c30303030363030",
            "302c687243587974716c6b337675306d6b6b5a4d2d56506f3059301306072a86",
            "48ce3d020106082a8648ce3d03010703420004994f712b57b48a9b6116bd8064",
            "dd5b2eb3d61ed36e5a208d558b77a0f87f3875de8c6dc1bfbf02019ff7e3728b",
            "7451f157cfb4e5acc7bead6ab48f20ad502795a360305e300c0603551d130101",
            "ff04023000301d0603551d0e041604145c1672eb2654e9fdbec4d4b48be3e4ac",
            "03781842301f0603551d23041830168014d0d56feb7d94f4535aa0cadd412835",
            "36cb3aa2bf300e0603551d0f0101ff040403020388300a06082a8648ce3d0403",
            "020348003045022100cdeb833d130860b97abac19dd3dde82b98ca0ffcf2525e",
            "fd81360c546260d3060220693a5433486c316a26b57dd1e23ee0b9206ba8805f",
            "3630f82b27a86106e0aefe"
        ].joined())!
    private let genuineBlock = Data(hexadecimalString: "f0daaad65799d7954ae377f96623187b6c0a614793834993b54a6333530e38f97dc72132c6b127cdc07d7a662602a0a00fc28aa6f059638588f0c4263a8d1a49")!
    private let genuineNonce = Data(hexadecimalString: "5d8ea3df8aec32584507dd4b23919df6")!

    // An emulator leaf signed by the g7sim dummy CA, with its own 0C signature.
    private let simLeaf = Data(hexadecimalString: [
            "308201513081f8a003020102020501cf977871300a06082a8648ce3d04030230",
            "133111300f06035504031308473753494d2d4341301e170d3236313031303232",
            "303831315a170d3237313131343233303831315a301b31193017060355040313",
            "10473753494d2d373737373737373737373059301306072a8648ce3d02010608",
            "2a8648ce3d03010703420004f0838b8b57389af16435f046520cb40b2d367980",
            "e18f8e7ed99f9bb6046da55a1445babc6e54ce74de8afef0fa1dfe86cc1a863b",
            "86b25b98d805e6aea7d7da98a331302f300c0603551d130101ff04023000301f",
            "0603551d2304183016801461e808e54c75334680ca4d6a2642a4c13ed34aed30",
            "0a06082a8648ce3d040302034800304502200ece748c0b18187a659f0f1d653c",
            "f862e1598be8d39d7c4446aca57fdb7b1a100221008176f475ea37c690984791",
            "4452023e071ad5f490b322ddef69cbd1fe08bb15d2"
        ].joined())!
    private let simBlock = Data(hexadecimalString: "08fba6f52ecdf3a67a24a12d8fac09b751eb440c269f4e7d1a75ba4292acd0a7b4aade034b332e9d954e2fa4b2fe5fde377fd52403ea068e39ca42f23f41d57a")!
    private let simNonce = Data(hexadecimalString: "000102030405060708090a0b0c0d0e0f")!

    func testGenuineSensorIsGenuine() {
        XCTAssertEqual(G7SensorIdentity.authenticity(leafCertificate: genuineLeaf, challengeSignature: genuineBlock, nonce: genuineNonce), .genuine)
    }

    func testEmulatorIsSimulated() {
        XCTAssertEqual(G7SensorIdentity.authenticity(leafCertificate: simLeaf, challengeSignature: simBlock, nonce: simNonce), .simulated)
    }

    func testTamperedSignatureIsUnverified() {
        var bad = genuineBlock
        bad[bad.startIndex] ^= 0xFF
        XCTAssertEqual(G7SensorIdentity.authenticity(leafCertificate: genuineLeaf, challengeSignature: bad, nonce: genuineNonce), .unverified)
    }

    func testWrongNonceIsUnverified() {
        let otherNonce = Data(repeating: 0x5A, count: 16)
        XCTAssertEqual(G7SensorIdentity.authenticity(leafCertificate: genuineLeaf, challengeSignature: genuineBlock, nonce: otherNonce), .unverified)
    }

    func testGarbageCertificateIsUnverified() {
        XCTAssertEqual(G7SensorIdentity.authenticity(leafCertificate: Data(repeating: 0, count: 100), challengeSignature: genuineBlock, nonce: genuineNonce), .unverified)
    }

    func testWrongLengthSignatureIsUnverified() {
        XCTAssertEqual(G7SensorIdentity.authenticity(leafCertificate: genuineLeaf, challengeSignature: Data(repeating: 0, count: 32), nonce: genuineNonce), .unverified)
    }
}
