import Foundation

/// How a text file is stored on disk, so a save writes it back the same way: encoding (and BOM) and line endings.
struct TextFormat: Equatable, Sendable {
    enum Encoding: String, CaseIterable, Sendable {
        case utf8 = "UTF-8"
        case utf8BOM = "UTF-8 with BOM"
        case utf16LE = "UTF-16 LE"
        case utf16BE = "UTF-16 BE"
        /// The fallback for 8-bit text that is not valid UTF-8 (Latin-1 superset; every byte decodes).
        case windows1252 = "Windows 1252"
    }

    enum LineEnding: String, CaseIterable, Sendable {
        case lf = "LF"
        case crlf = "CRLF"
        case cr = "CR"

        var text: String {
            switch self {
            case .lf: "\n"
            case .crlf: "\r\n"
            case .cr: "\r"
            }
        }
    }

    var encoding: Encoding = .utf8
    var lineEnding: LineEnding = .lf
}

/// Reads and writes text files faithfully. Pure, so every rule is asserted directly.
enum TextFile {
    enum Decoded: Equatable {
        case text(String, TextFormat)
        /// NUL bytes in the first 8 KB without a UTF-16 BOM: not text.
        case binary
    }

    static func decode(_ data: Data) -> Decoded {
        let bytes = [UInt8](data.prefix(4))
        var format = TextFormat()
        let body: String?
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            format.encoding = .utf8BOM
            body = String(data: data.dropFirst(3), encoding: .utf8)
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            format.encoding = .utf16LE
            body = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            format.encoding = .utf16BE
            body = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else if data.prefix(8_192).contains(0) {
            return .binary
        } else if let utf8 = String(data: data, encoding: .utf8) {
            body = utf8
        } else {
            format.encoding = .windows1252
            body = String(data: data, encoding: .windowsCP1252)
        }
        guard let body else { return .binary }
        format.lineEnding = lineEnding(of: body)
        return .text(body, format)
    }

    /// The first line break decides; a file with none is LF. On unicode scalars: "\r\n" is ONE Character.
    static func lineEnding(of text: String) -> TextFormat.LineEnding {
        var scalars = text.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            if scalar == "\n" { return .lf }
            if scalar == "\r" { return scalars.next() == "\n" ? .crlf : .cr }
        }
        return .lf
    }

    /// Bytes for `text` in `format`'s encoding (BOM included). Throws when a character has no encoding there.
    static func encode(_ text: String, as format: TextFormat) throws -> Data {
        let (encoding, bom): (String.Encoding, [UInt8]) =
            switch format.encoding {
            case .utf8: (.utf8, [])
            case .utf8BOM: (.utf8, [0xEF, 0xBB, 0xBF])
            case .utf16LE: (.utf16LittleEndian, [0xFF, 0xFE])
            case .utf16BE: (.utf16BigEndian, [0xFE, 0xFF])
            case .windows1252: (.windowsCP1252, [])
            }
        guard let body = text.data(using: encoding, allowLossyConversion: false) else {
            throw FileOps.Failure(message: "Some characters can't be saved as \(format.encoding.rawValue). Convert the file to UTF-8 first.")
        }
        return Data(bom) + body
    }

    /// Every line break in `text` rewritten as `ending` (mixed endings included).
    static func convert(_ text: String, to ending: TextFormat.LineEnding) -> String {
        var out = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        var pending = scalars.next()
        while let scalar = pending {
            pending = scalars.next()
            if scalar == "\r" {
                if pending == "\n" { pending = scalars.next() }
                out.append(contentsOf: ending.text.unicodeScalars)
            } else if scalar == "\n" {
                out.append(contentsOf: ending.text.unicodeScalars)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}
