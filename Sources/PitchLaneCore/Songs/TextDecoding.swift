import Foundation

/// Text decoding for imported files: UTF-8 (with or without BOM), UTF-16 with BOM, otherwise
/// Windows-1252 (a superset of printable Latin-1, which is what most older UltraStar files use).
public enum TextDecoding {
    public static func decode(_ data: Data) -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: bytes.dropFirst(3), as: UTF8.self)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        if let text = String(validating: bytes, as: UTF8.self) {
            return text
        }
        return windows1252(bytes)
    }

    /// Bytes 0x80-0x9F that Windows-1252 maps away from Latin-1 (undefined ones stay as-is).
    private static let cp1252High: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    public static func windows1252(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for byte in bytes {
            let value = (0x80...0x9F).contains(byte) ? cp1252High[Int(byte) - 0x80] : UInt32(byte)
            if let scalar = Unicode.Scalar(value) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}
