//
//  G7SensorPackageTests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
@testable import G7SensorKit

class G7SensorPackageTests: XCTestCase {

    private let gs = "\u{1D}"

    /// GTIN, expiry, lot, serial, pairing code: the fields on a sensor box,
    /// with the variable-length ones separated by FNC1.
    private var samplePayload: String {
        "0100386270001863" + "17260531" + "10LOT42" + gs + "21123456789012" + gs + "2401155"
    }

    func testParsesASensorBox() throws {
        let package = try XCTUnwrap(G7SensorPackage(dataMatrix: samplePayload))
        XCTAssertEqual(package.gtin, "00386270001863")
        XCTAssertEqual(package.expiry, "260531")
        XCTAssertEqual(package.lot, "LOT42")
        XCTAssertEqual(package.serial, "123456789012")
        XCTAssertEqual(package.pairingCode, "1155")
        XCTAssertTrue(package.isDexcom)
    }

    func testSymbologyIdentifierAndLeadingSeparatorAreSkipped() throws {
        let package = try XCTUnwrap(G7SensorPackage(dataMatrix: "]d2" + gs + samplePayload))
        XCTAssertEqual(package.pairingCode, "1155")
        XCTAssertEqual(package.serial, "123456789012")
    }

    func testFieldOrderDoesNotMatter() throws {
        let package = try XCTUnwrap(G7SensorPackage(dataMatrix: "2401155" + gs + "21123456789012" + gs + "0100386270001863"))
        XCTAssertEqual(package.pairingCode, "1155")
        XCTAssertEqual(package.serial, "123456789012")
        XCTAssertEqual(package.gtin, "00386270001863")
    }

    func testPairingCodeFieldAtEndNeedsNoSeparator() throws {
        let package = try XCTUnwrap(G7SensorPackage(dataMatrix: "21123456789012" + gs + "2400420"))
        XCTAssertEqual(package.pairingCode, "0420")
    }

    /// AI 240 is a general product identifier; only a four-digit value is a
    /// pairing code.
    func testNonCodeValueInAI240IsIgnored() throws {
        let package = try XCTUnwrap(G7SensorPackage(dataMatrix: "0100386270001863" + "240ABC123"))
        XCTAssertNil(package.pairingCode)
        XCTAssertEqual(package.gtin, "00386270001863")
    }

    func testOtherManufacturer() throws {
        let package = try XCTUnwrap(G7SensorPackage(dataMatrix: "0100123456789012"))
        XCTAssertFalse(package.isDexcom)
    }

    func testUnrelatedBarcodeIsRejected() {
        XCTAssertNil(G7SensorPackage(dataMatrix: "https://example.com"))
        XCTAssertNil(G7SensorPackage(dataMatrix: ""))
    }

    func testUnknownIdentifierStopsParsingWithoutLosingEarlierFields() throws {
        // "42" is not an identifier this parser knows.
        let package = try XCTUnwrap(G7SensorPackage(dataMatrix: "2401155" + gs + "42junk"))
        XCTAssertEqual(package.pairingCode, "1155")
    }

    func testLongestIdentifierWins() {
        // "240..." must not be read as AI 24 (unknown) or AI 2 (nonexistent).
        XCTAssertEqual(GS1ElementString.parse("2401155")["240"], "1155")
        XCTAssertNil(GS1ElementString.parse("2401155")["24"])
    }
}
