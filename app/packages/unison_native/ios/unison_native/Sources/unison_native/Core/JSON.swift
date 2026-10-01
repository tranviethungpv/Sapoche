import Foundation

/// Any JSON value, read the forgiving way: asking for something that is not there gives nil or nothing, never a crash.
/// YouTube's answers are not promised to anybody, so every reader goes through this.
struct JSON {
    let raw: Any?

    init(_ raw: Any?) {
        self.raw = raw is NSNull ? nil : raw
    }

    static func parse(_ text: String) -> JSON? {
        parse(data: Data(text.utf8))
    }

    static func parse(data: Data) -> JSON? {
        guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSON(value)
    }

    /// The value under [key] when this is an object.
    subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    /// The value at [index] when this is an array.
    subscript(index: Int) -> JSON {
        guard let list = raw as? [Any], index >= 0, index < list.count else { return JSON(nil) }
        return JSON(list[index])
    }

    /// The element under [path], where each step is a key of an object or a position in an array.
    func at(_ path: String...) -> JSON {
        var node = self
        for step in path {
            if node.raw is [String: Any] {
                node = node[step]
            } else if let position = Int(step) {
                node = node[position]
            } else {
                return JSON(nil)
            }
        }
        return node
    }

    var isNull: Bool { raw == nil }

    var object: [String: Any]? { raw as? [String: Any] }

    var array: [JSON] { (raw as? [Any])?.map { JSON($0) } ?? [] }

    /// Text; a number or a flag is given as its text, like a JSON primitive.
    var string: String? {
        switch raw {
        case let text as String: return text
        case let flag as Bool: return flag ? "true" : "false"
        case let number as Int: return String(number)
        case let number as Int64: return String(number)
        case let number as Double:
            return number == number.rounded() && abs(number) < 9e15 ? String(Int64(number)) : String(number)
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    var int64: Int64? {
        switch raw {
        case let number as Int: return Int64(number)
        case let number as Int64: return number
        case let number as Double: return number.isFinite ? Int64(number) : nil
        case let number as NSNumber: return number.int64Value
        case let text as String: return Int64(text)
        default: return nil
        }
    }

    var int: Int? { int64.map { Int($0) } }

    var double: Double? {
        switch raw {
        case let number as Double: return number
        case let number as Int: return Double(number)
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }

    var bool: Bool? {
        switch raw {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        default: return nil
        }
    }

    /// Every value under [key], wherever it is in the tree.
    func findAll(_ key: String) -> [JSON] {
        var found: [JSON] = []
        func walk(_ node: Any?) {
            if let object = node as? [String: Any] {
                for (name, value) in object {
                    if name == key { found.append(JSON(value)) } else { walk(value) }
                }
            } else if let list = node as? [Any] {
                list.forEach(walk)
            }
        }
        walk(raw)
        return found
    }
}

enum JSONText {
    /// [value] (dictionaries, arrays, strings, numbers, bools) as compact JSON text.
    static func encode(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber,
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
