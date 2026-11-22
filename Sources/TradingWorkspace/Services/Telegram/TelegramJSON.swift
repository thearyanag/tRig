import Foundation

/// Keeps TDLib's numeric identifiers exact and its packets safe to move between threads.
enum TelegramJSON: Codable, Sendable {
  case object([String: Self]), array([Self]), string(String), integer(Int64)
  case number(Double), bool(Bool), null

  init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() { self = .null }
    else if let item = try? value.decode(Bool.self) { self = .bool(item) }
    else if let item = try? value.decode(Int64.self) { self = .integer(item) }
    else if let item = try? value.decode(Double.self) { self = .number(item) }
    else if let item = try? value.decode(String.self) { self = .string(item) }
    else if let item = try? value.decode([Self].self) { self = .array(item) }
    else { self = .object(try value.decode([String: Self].self)) }
  }

  func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .null: try value.encodeNil()
    case .object(let item): try value.encode(item)
    case .array(let item): try value.encode(item)
    case .string(let item): try value.encode(item)
    case .integer(let item): try value.encode(item)
    case .number(let item): try value.encode(item)
    case .bool(let item): try value.encode(item)
    }
  }

  subscript(key: String) -> Self {
    guard case .object(let values) = self else { return .null }
    return values[key] ?? .null
  }

  var string: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var int: Int64? {
    if case .integer(let value) = self { return value }
    return string.flatMap(Int64.init)
  }

  var bool: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  var array: [Self]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  var type: String? { self["@type"].string }

  static func object(_ type: String, _ fields: [String: Self] = [:]) -> Self {
    var value = fields
    value["@type"] = .string(type)
    return .object(value)
  }
}
