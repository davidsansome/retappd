import Foundation

/// The Untappd API is loosely typed: numbers arrive as strings, objects arrive as `[]`
/// when empty, and fields come and go between endpoints. These helpers never throw;
/// they return nil for anything missing or unexpectedly shaped.
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

extension KeyedDecodingContainer where Key == AnyKey {
    func obj<T: Decodable>(_ key: String, _ type: T.Type = T.self) -> T? {
        (try? decodeIfPresent(T.self, forKey: AnyKey(key))) ?? nil
    }

    func string(_ key: String) -> String? {
        let k = AnyKey(key)
        if let s = try? decodeIfPresent(String.self, forKey: k) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: k) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: k) { return String(d) }
        return nil
    }

    /// A non-empty string, or nil.
    func text(_ key: String) -> String? {
        guard let s = string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    func double(_ key: String) -> Double? {
        let k = AnyKey(key)
        if let d = try? decodeIfPresent(Double.self, forKey: k) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: k) { return Double(s) }
        return nil
    }

    func int(_ key: String) -> Int? {
        let k = AnyKey(key)
        if let i = try? decodeIfPresent(Int.self, forKey: k) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: k) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: k) { return Int(s) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        let k = AnyKey(key)
        if let b = try? decodeIfPresent(Bool.self, forKey: k) { return b }
        if let i = try? decodeIfPresent(Int.self, forKey: k) { return i != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: k) { return s == "1" || s == "true" }
        return nil
    }

    func nested(_ key: String) -> KeyedDecodingContainer<AnyKey>? {
        try? nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(key))
    }

    /// Decodes `{ "items": [...] }` (Untappd's usual list wrapper), dropping elements that fail.
    func items<T: Decodable>(_ key: String, _ type: T.Type = T.self) -> [T] {
        guard let n = nested(key) else { return [] }
        return n.list("items")
    }

    /// Decodes an array, dropping elements that fail to decode.
    func list<T: Decodable>(_ key: String, _ type: T.Type = T.self) -> [T] {
        (obj(key, [Failable<T>].self) ?? []).compactMap(\.value)
    }
}

struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

enum UntappdDate {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return formatter.date(from: s)
    }
}
