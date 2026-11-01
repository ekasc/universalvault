import Core
import XCTest

final class UnicodeEventChunksTests: XCTestCase {
  func testUnicodeChunksPreserveUTF16WithoutSplittingSurrogates() {
    for input in [
      "", "Café 日本語 🧪", String(repeating: "👨‍👩‍👧‍👦", count: 25), String(repeating: "a\u{301}", count: 50),
    ] {
      let chunks = UnicodeEventChunks.split(input)
      XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
      XCTAssertEqual(chunks.flatMap { $0 }, Array(input.utf16))
      for chunk in chunks {
        XCTAssertEqual(Array(String(decoding: chunk, as: UTF16.self).utf16), chunk)
      }
    }
  }
}
