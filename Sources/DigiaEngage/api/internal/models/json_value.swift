import Foundation

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        // Prefer structured container probes over "try decode X" cascades.
        // This avoids deep type-mismatch error construction/backtracking in JSONDecoder,
        // which can crash on very large / deeply nested payloads.
        if let keyed = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            var object: [String: JSONValue] = [:]
            object.reserveCapacity(keyed.allKeys.count)
            for key in keyed.allKeys {
                let valueDecoder = try keyed.superDecoder(forKey: key)
                object[key.stringValue] = try JSONValue(from: valueDecoder)
            }
            self = .object(object)
            return
        }

        if var unkeyed = try? decoder.unkeyedContainer() {
            var array: [JSONValue] = []
            array.reserveCapacity(unkeyed.count ?? 0)
            while !unkeyed.isAtEnd {
                let valueDecoder = try unkeyed.superDecoder()
                array.append(try JSONValue(from: valueDecoder))
            }
            self = .array(array)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "Unsupported JSON value for JSONValue")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var anyValue: Any? {
        switch self {
        case let .string(value):
            return value
        case let .int(value):
            return value
        case let .double(value):
            return value
        case let .bool(value):
            return value
        case let .array(value):
            return value.map(\.anyValue)
        case let .object(value):
            return value.mapValues(\.anyValue)
        case .null:
            return nil
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
