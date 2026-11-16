import Foundation

/// The most properties one event keeps.
let appEventMaxProperties = 100

/// The longest property key the backend stores.
let appEventPropertyKeyMaxLength = 120

/// The longest app-event name the backend stores.
let appEventNameMaxLength = 120

/// Strings longer than this are cut, as the server does, so the event is kept.
let appEventPropertyStringMaxLength = 512

/// The most items a list value keeps, as the server does.
let appEventPropertyListMaxItems = 100

/// The app-event limits the backend stores to, from the SDK config. The defaults
/// stand before the config answers and for a missing or invalid value.
struct AppEventLimits: Equatable, Sendable {
    var nameMaxLength = appEventNameMaxLength
    var maxProperties = appEventMaxProperties
    var propertyKeyMaxLength = appEventPropertyKeyMaxLength
    var stringMaxLength = appEventPropertyStringMaxLength
    var listMaxItems = appEventPropertyListMaxItems

    static let defaults = AppEventLimits()
}

/// Whether `name`, already trimmed, is a name the backend accepts. Length is
/// counted in UTF-16 code units, as the backend (and the Flutter SDK) does.
func isValidAppEventName(_ name: String, limits: AppEventLimits = .defaults) -> Bool {
    !name.isEmpty && name.utf16.count <= limits.nameMaxLength
}

/// `properties` reduced to the value types the backend stores: strings, finite
/// numbers, booleans, and lists of those. Strings are cut to
/// ``AppEventLimits/stringMaxLength`` and lists to ``AppEventLimits/listMaxItems``.
/// A key longer than ``AppEventLimits/propertyKeyMaxLength`` is dropped, as is every
/// property past ``AppEventLimits/maxProperties`` (keys are taken in sorted order).
/// A bad value costs that key, or that list item, never the event; `dropped`
/// names every key that lost something.
func cleanAppEventProperties(
    _ properties: [String: Any],
    limits: AppEventLimits = .defaults
) -> (properties: [String: Any], dropped: [String]) {
    var clean: [String: Any] = [:]
    var dropped: [String] = []
    for key in properties.keys.sorted() {
        let value = properties[key] as Any
        if key.utf16.count > limits.propertyKeyMaxLength || clean.count >= limits.maxProperties {
            dropped.append(key)
        } else if let list = value as? [Any] {
            let items = list.prefix(limits.listMaxItems).compactMap { scalar($0, limits.stringMaxLength) }
            if items.count < min(list.count, limits.listMaxItems) {
                dropped.append(key)
            }
            clean[key] = items
        } else if let kept = scalar(value, limits.stringMaxLength) {
            clean[key] = kept
        } else {
            dropped.append(key)
        }
    }
    return (clean, dropped)
}

/// The value as stored, or nil when the backend has no type for it. A
/// non-finite number is dropped too: JSON cannot encode it.
private func scalar(_ value: Any, _ stringMax: Int) -> Any? {
    switch value {
    case let string as String:
        return string.utf16.count > stringMax ? cutString(string, stringMax) : string
    case let number as NSNumber:
        // Bool bridges to NSNumber; keep it a boolean on the wire.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        return number.doubleValue.isFinite ? number : nil
    case let double as Double:
        return double.isFinite ? double : nil
    case let float as Float:
        return float.isFinite ? float : nil
    case is Int, is Int8, is Int16, is Int32, is Int64, is UInt, is UInt8, is UInt16, is UInt32, is UInt64:
        return value
    case is Bool:
        return value
    default:
        return nil
    }
}

private func cutString(_ value: String, _ max: Int) -> String {
    var units = Array(value.utf16.prefix(max))
    // A high surrogate at the cut would be left without its pair.
    if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
    return String(decoding: units, as: UTF16.self)
}
