import Foundation

/// A JSON value used to walk Notion's irregular public API payloads.
public enum JSONValue: Sendable, Hashable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object: [String: JSONValue] = [:]
        object.reserveCapacity(elements.count)
        for (key, value) in elements {
            object[key] = value
        }
        self = .object(object)
    }
}

extension JSONValue {
    public subscript(key: String) -> JSONValue {
        if case .object(let object) = self {
            return object[key] ?? .null
        }
        return .null
    }

    public subscript(index: Int) -> JSONValue {
        if case .array(let array) = self, array.indices.contains(index) {
            return array[index]
        }
        return .null
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var int: Int? {
        guard let number, number.rounded() == number else { return nil }
        return Int(number)
    }

    public var array: [JSONValue] {
        if case .array(let value) = self { return value }
        return []
    }

    public var object: [String: JSONValue] {
        if case .object(let value) = self { return value }
        return [:]
    }

    public static func parse(data: Data) throws -> JSONValue {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try JSONValue(raw)
    }

    public func encodedData(prettyPrinted: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .sortedKeys]
        if prettyPrinted {
            options.insert(.prettyPrinted)
        }
        return try JSONSerialization.data(withJSONObject: jsonObject(), options: options)
    }

    public init(_ raw: Any) throws {
        switch raw {
        case is NSNull:
            self = .null
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if JSONValue.isBooleanNumber(value) {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as Bool:
            self = .bool(value)
        case let value as [Any]:
            self = .array(try value.map(JSONValue.init))
        case let value as [String: Any]:
            self = .object(try value.mapValues(JSONValue.init))
        default:
            throw NotionSiteFetchError.invalidJSON("Unsupported JSON fragment \(type(of: raw))")
        }
    }

    func jsonObject() -> Any {
        switch self {
        case .object(let object):
            return object.mapValues { $0.jsonObject() }
        case .array(let array):
            return array.map { $0.jsonObject() }
        case .string(let value):
            return value
        case .number(let value):
            if value.rounded() == value,
               value >= Double(Int.min),
               value <= Double(Int.max) {
                return Int(value)
            }
            return value
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }

    private static func isBooleanNumber(_ number: NSNumber) -> Bool {
        #if os(Linux)
        let type = String(cString: number.objCType)
        return type == "c" || type == "B"
        #else
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #endif
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String {
        (try? String(data: encodedData(), encoding: .utf8)) ?? "<invalid json>"
    }
}
