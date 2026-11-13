import Foundation

/// Helpers for forgiving decoding of the app's own JSON files: one bad field or one bad entry must not
/// make a whole file unreadable (and an unreadable file would otherwise be replaced by defaults).
extension KeyedDecodingContainer {
    /// The value, or nil when the key is missing or holds the wrong type / an unknown enum case.
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// Decodes to nil instead of throwing, for skipping bad elements of an array or dictionary.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
