enum QuoteAmount {
  static func isPositive(_ text: String) -> Bool {
    guard text.count <= 300 else { return false }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    let digits = text.filter { $0 != "." }
    return parts.count <= 2 && digits.allSatisfy { $0.isASCII && $0.isNumber }
      && digits.contains { $0 != "0" }
  }
}
