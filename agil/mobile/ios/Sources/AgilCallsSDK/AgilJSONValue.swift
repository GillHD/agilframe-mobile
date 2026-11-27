import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// A JSON-safe value for opaque payloads (tenant config, bridge events, chat
/// metadata).
///
/// The SDK never exposes raw `Any`/`NSDictionary` values from the WebView or the
/// REST API: everything goes through ``AgilJSONSanitizer`` first, which enforces
/// depth/size limits and drops prototype-polluting keys.
public enum AgilJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgilJSONValue])
    case object([String: AgilJSONValue])

    public var isNull: Bool {
        if case .null = self {
            return true
        }
        return false
    }

    public var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self {
            return value
        }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }

    /// Integer view of a JSON number, or `nil` when it is not an integer.
    public var intValue: Int? {
        guard let number = doubleValue,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= Double(Int.min),
              number <= Double(Int.max) else {
            return nil
        }
        return Int(number)
    }

    public var arrayValue: [AgilJSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }

    public var objectValue: [String: AgilJSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    /// Convenience accessor for object values; returns `nil` for other kinds.
    public subscript(key: String) -> AgilJSONValue? {
        return objectValue?[key]
    }

    /// Foundation representation suitable for `JSONSerialization`.
    ///
    /// Only used internally to encode theme patches. Values are already
    /// sanitized, so this never contains functions, cycles or non-finite
    /// numbers.
    public var jsonObject: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map { $0.jsonObject }
        case .object(let values):
            var result: [String: Any] = [:]
            for (key, value) in values {
                result[key] = value.jsonObject
            }
            return result
        }
    }
}

/// Sanitizes untrusted JSON-like values before they reach the public API.
///
/// Rules (mirrors the JS/Dart SDKs):
///  - only `null`, booleans, finite numbers, strings, arrays and string-keyed
///    objects survive;
///  - containers are capped (depth 8 by default, 100 elements/keys);
///  - strings are capped at 32 KiB;
///  - `__proto__`, `prototype` and `constructor` keys are dropped;
///  - cycles cannot occur for Swift collections but are bounded by the depth
///    limit for bridged `NSDictionary`/`NSArray` graphs.
enum AgilJSONSanitizer {
    struct Limits {
        var maxDepth: Int = 8
        var maxArray: Int = 100
        var maxKeys: Int = 100
        var maxString: Int = 32_768

        static let `default` = Limits()
        /// Tenant config objects are larger than bridge events but still bounded.
        static let response = Limits(maxDepth: 12, maxArray: 500, maxKeys: 500, maxString: 65_536)
    }

    private static let forbiddenKeys: Set<String> = [
        "__proto__",
        "prototype",
        "constructor"
    ]

    static func isForbiddenKey(_ key: String) -> Bool {
        return forbiddenKeys.contains(key)
    }

    /// Returns a sanitized value, or `nil` when the input is not JSON-safe.
    ///
    /// `nil` entries inside arrays become `null` and `nil` object members are
    /// dropped, matching `JSON.stringify` semantics.
    static func sanitize(
        _ value: Any?,
        limits: Limits = .default,
        depth: Int = 0
    ) -> AgilJSONValue? {
        guard let value = value else {
            return nil
        }
        if value is NSNull {
            return .null
        }
        if let string = value as? String {
            return .string(truncate(string, to: limits.maxString))
        }
        if let number = value as? NSNumber {
            if isBoolean(number) {
                return .bool(number.boolValue)
            }
            let double = number.doubleValue
            guard double.isFinite else {
                return nil
            }
            return .number(double)
        }
        if let boolean = value as? Bool {
            return .bool(boolean)
        }
        guard depth < limits.maxDepth else {
            return nil
        }
        if let array = value as? [Any] {
            let capped = array.prefix(max(0, limits.maxArray))
            return .array(capped.map { sanitize($0, limits: limits, depth: depth + 1) ?? .null })
        }
        if let dictionary = value as? [String: Any] {
            return object(from: dictionary, limits: limits, depth: depth)
        }
        if let dictionary = value as? [AnyHashable: Any] {
            var stringKeyed: [String: Any] = [:]
            for (key, item) in dictionary {
                guard let key = key as? String else {
                    continue
                }
                stringKeyed[key] = item
            }
            return object(from: stringKeyed, limits: limits, depth: depth)
        }
        return nil
    }

    private static func object(
        from dictionary: [String: Any],
        limits: Limits,
        depth: Int
    ) -> AgilJSONValue {
        var result: [String: AgilJSONValue] = [:]
        var count = 0
        for (key, item) in dictionary {
            if count >= limits.maxKeys {
                break
            }
            if isForbiddenKey(key) {
                continue
            }
            guard let sanitized = sanitize(item, limits: limits, depth: depth + 1) else {
                continue
            }
            result[key] = sanitized
            count += 1
        }
        return .object(result)
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(CoreFoundation)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        return false
        #endif
    }

    private static func truncate(_ value: String, to limit: Int) -> String {
        guard limit > 0 else {
            return ""
        }
        guard value.count > limit else {
            return value
        }
        return String(value.prefix(limit - 1)) + "…"
    }
}
