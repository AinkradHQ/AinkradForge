import Foundation
import Testing

@testable import ForgeFeature

@Suite("Text files")
struct TextFileTests {
    @Test func plainUTF8WithLF() {
        #expect(TextFile.decode(Data("a\nb\n".utf8)) == .text("a\nb\n", TextFormat(encoding: .utf8, lineEnding: .lf)))
    }

    @Test func bomsAreRecognisedAndKeptOnSave() throws {
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("x\r\ny".utf8)
        guard case .text(let text, let format) = TextFile.decode(bom) else { Issue.record("not text"); return }
        #expect(text == "x\r\ny")
        #expect(format == TextFormat(encoding: .utf8BOM, lineEnding: .crlf))
        #expect(try TextFile.encode(text, as: format) == bom)

        let utf16 = Data([0xFF, 0xFE]) + "héllo".data(using: .utf16LittleEndian)!
        guard case .text(let wide, let wideFormat) = TextFile.decode(utf16) else { Issue.record("not text"); return }
        #expect(wide == "héllo" && wideFormat.encoding == .utf16LE)
        #expect(try TextFile.encode(wide, as: wideFormat) == utf16)
    }

    @Test func invalidUTF8FallsBackTo1252AndRoundTrips() throws {
        let latin = Data([0x63, 0x61, 0x66, 0xE9])  // "café" in Latin-1 / 1252
        guard case .text(let text, let format) = TextFile.decode(latin) else { Issue.record("not text"); return }
        #expect(text == "café" && format.encoding == .windows1252)
        #expect(try TextFile.encode(text, as: format) == latin)
        #expect(throws: FileOps.Failure.self) { try TextFile.encode("🙂", as: format) }
    }

    @Test func nulBytesMeanBinary() {
        #expect(TextFile.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])) == .binary)
    }

    /// "\r\n" is one Swift Character — line endings are read on unicode scalars.
    @Test func lineEndingsAreDetectedAndConverted() {
        #expect(TextFile.lineEnding(of: "a\r\nb") == .crlf)
        #expect(TextFile.lineEnding(of: "a\rb") == .cr)
        #expect(TextFile.lineEnding(of: "no break") == .lf)
        #expect(TextFile.convert("a\r\nb\nc\rd", to: .lf) == "a\nb\nc\nd")
        #expect(TextFile.convert("a\nb", to: .crlf) == "a\r\nb")
    }
}
