import XCTest
import Core

final class CommaSeparatedValuesTests: XCTestCase {
    func testRoundTripPreservesImportedValues() {
        let values = ["legal,name", "quote\"inside", " space ", "", "日本語", "line\nbreak"]
        XCTAssertEqual(CommaSeparatedValues.parse(CommaSeparatedValues.format(values)), values)
    }

    func testUnquotedInputTrimsWhitespaceAndSkipsEmptyEntries() {
        XCTAssertEqual(CommaSeparatedValues.parse(" work, personal, , "), ["work", "personal"])
        XCTAssertEqual(CommaSeparatedValues.parse(""), [])
        XCTAssertEqual(CommaSeparatedValues.parse(CommaSeparatedValues.format([])), [])
    }

    func testQuotedCommasAndEscapedQuotesAreNotSeparators() {
        XCTAssertEqual(CommaSeparatedValues.parse("\"last, first\", \"say \"\"hello\"\"\""), ["last, first", "say \"hello\""])
    }

    func testIncompleteQuotedInputDoesNotProduceAPartialSave() {
        XCTAssertNil(CommaSeparatedValues.parse("work, \"last, first"))
        XCTAssertNil(CommaSeparatedValues.parse("\"closed\"extra"))
    }

    func testQuotedEmptyAndWhitespaceValuesArePreserved() {
        XCTAssertEqual(CommaSeparatedValues.parse("\"\", \" \""), ["", " "])
    }
}
