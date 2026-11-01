public enum UnicodeEventChunks {
  public static func split(_ text: String) -> [[UInt16]] {
    let units = Array(text.utf16)
    var chunks: [[UInt16]] = []
    var start = 0
    while start < units.count {
      var end = min(start + 20, units.count)
      if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) { end -= 1 }
      chunks.append(Array(units[start..<end]))
      start = end
    }
    return chunks
  }
}
