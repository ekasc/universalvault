import XCTest
import Core

final class ModelsTests: XCTestCase {
    func testItemCreationAndSearch() {
        var payload = VaultPayload()
        let item = VaultItem(title: "My Information", fields: [
            VaultField(key: "email1", label: "Email", type: .email, value: .email("a@b.com"), aliases: ["E-mail"]),
            VaultField(key: "fn", label: "First Name", type: .text, value: .text("Jane"))
        ])
        payload.items.append(item)
        let engine = SearchEngine()
        let r = engine.search(query: "email", payload: payload)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.field.label, "Email")
        let r2 = engine.search(query: "given", payload: payload) // alias not matching
        XCTAssertEqual(r2.count, 0)
        let r3 = engine.search(query: "first", payload: payload)
        XCTAssertEqual(r3.count, 1)
    }
    func testJSONRoundTrip() throws {
        var item = VaultItem(title: "T", fields: [VaultField(key:"k",label:"L",type:.text,value:.text("v"))])
        let data = try JSONEncoder().encode(item)
        let dec = try JSONDecoder().decode(VaultItem.self, from: data)
        XCTAssertEqual(dec, item)
    }
    func testFieldValidation() {
        let f = VaultField(key:"", label:"", type:.text)
        let errs = Validation.validateField(f)
        XCTAssertFalse(errs.isEmpty)
    }

    func testLargeNumberInsertionText() {
        let huge = VaultField(key: "n", label: "N", type: .number, value: .number(Double.greatestFiniteMagnitude))
        XCTAssertFalse(huge.insertionText.contains("inf"))
        let maxIntLike = Double(Int.max) + 999.0
        let field = VaultField(key: "n2", label: "N2", type: .number, value: .number(maxIntLike))
        XCTAssertEqual(field.insertionText, "9223372036854775808")
        let integer = VaultField(key: "n3", label: "N3", type: .number, value: .number(42.0))
        XCTAssertEqual(integer.insertionText, "42")
        let dateField = VaultField(key: "d", label: "D", type: .date, value: .date(Date(timeIntervalSince1970: 0)), preferredInsertFormat: "yyyy-MM-dd")
        XCTAssertFalse(dateField.insertionText.isEmpty)
    }

}
