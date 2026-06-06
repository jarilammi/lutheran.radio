//
//  StreamProgramMetadataTests.swift
//  Lutheran RadioTests
//

import XCTest
@testable import Lutheran_Radio

final class StreamProgramMetadataTests: XCTestCase {

    func testFromRawTitleOnly() {
        let metadata = StreamProgramMetadata.from(rawICYMetadata: "Sunday Sermon on Grace")
        XCTAssertEqual(metadata?.programTitle, "Sunday Sermon on Grace")
        XCTAssertNil(metadata?.speaker)
    }

    func testFromRawSpeakerDashTitle() {
        let metadata = StreamProgramMetadata.from(rawICYMetadata: "Pastor Smith - The Good Shepherd")
        XCTAssertEqual(metadata?.speaker, "Pastor Smith")
        XCTAssertEqual(metadata?.programTitle, "The Good Shepherd")
    }

    func testFromRawTitleBySpeaker() {
        let metadata = StreamProgramMetadata.from(rawICYMetadata: "Evening Vespers by Rev. Anna K.")
        XCTAssertEqual(metadata?.programTitle, "Evening Vespers")
        XCTAssertEqual(metadata?.speaker, "Rev. Anna K.")
    }

    func testFromEmptyReturnsNil() {
        XCTAssertNil(StreamProgramMetadata.from(rawICYMetadata: nil))
        XCTAssertNil(StreamProgramMetadata.from(rawICYMetadata: "   "))
    }
}