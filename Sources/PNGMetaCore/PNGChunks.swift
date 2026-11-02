import Foundation
import zlib

public enum PNGError: Error, Equatable, Sendable {
    case notPNG
    case truncated
}

public struct PNGImageInfo: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var bitDepth: Int
    public var colorType: Int
    public var compression: Int
    public var filter: Int
    public var interlace: Int
}

public struct PNGPhysical: Equatable, Sendable {
    public var pixelsPerUnitX: Int
    public var pixelsPerUnitY: Int
    public var unitIsMeter: Bool
    public var dpiX: Double?
    public var dpiY: Double?
}

public struct PNGText: Equatable, Sendable, Identifiable {
    public var index: Int
    public var kind: Kind
    public var keyword: String
    public var text: String
    public var language: String
    public var translatedKeyword: String

    public var id: Int { index }

    public enum Kind: String, Equatable, Sendable {
        case text = "tEXt"
        case compressed = "zTXt"
        case international = "iTXt"
    }
}

public struct PNGChunkRecord: Equatable, Sendable, Identifiable {
    public var index: Int
    public var type: String
    public var length: Int
    public var crcOK: Bool

    public var id: Int { index }
}

public enum PNGWarning: Equatable, Sendable {
    case crcMismatch(type: String, index: Int)
    case inflateFailed(kind: PNGText.Kind, keyword: String)
    case unsupportedCompression(kind: PNGText.Kind, keyword: String)
    case invalidUTF8(kind: PNGText.Kind, keyword: String)
    case invalidChunk(type: String)
}

public struct PNGDocument: Equatable, Sendable {
    public var image: PNGImageInfo?
    public var physical: PNGPhysical?
    public var modificationTime: Date?
    public var texts: [PNGText]
    public var chunks: [PNGChunkRecord]
    public var warnings: [PNGWarning]
}

public func parsePNG(_ data: Data) throws -> PNGDocument {
    var parser = PNGParser(data: data)
    return try parser.parse()
}

private let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

private struct PNGParser {
    let data: Data
    var index = 0
    var image: PNGImageInfo?
    var physical: PNGPhysical?
    var modificationTime: Date?
    var texts: [PNGText] = []
    var chunks: [PNGChunkRecord] = []
    var warnings: [PNGWarning] = []

    mutating func parse() throws -> PNGDocument {
        guard data.count >= pngSignature.count else { throw PNGError.notPNG }
        guard data.prefix(pngSignature.count).elementsEqual(pngSignature) else { throw PNGError.notPNG }
        index = pngSignature.count

        while index < data.count {
            guard data.count - index >= 12 else { throw PNGError.truncated }
            let length = Int(try readU32())
            let typeStart = index
            guard let type = readType() else { throw PNGError.truncated }
            guard length >= 0, length <= data.count - index - 4 else { throw PNGError.truncated }
            let payload = index..<(index + length)
            index += length
            let storedCRC = try readU32()
            let expectedCRC = PNGCRC.hash(data: data, range: typeStart..<(typeStart + 4 + length))
            let crcOK = storedCRC == expectedCRC
            let record = PNGChunkRecord(index: chunks.count, type: type, length: length, crcOK: crcOK)
            if !crcOK {
                warnings.append(.crcMismatch(type: type, index: record.index))
            }
            chunks.append(record)
            parseChunk(type: type, payload: payload)
        }

        return PNGDocument(
            image: image,
            physical: physical,
            modificationTime: modificationTime,
            texts: texts,
            chunks: chunks,
            warnings: warnings
        )
    }

    private mutating func parseChunk(type: String, payload: Range<Int>) {
        switch type {
        case "IHDR":
            parseIHDR(payload)
        case "pHYs":
            parsePHYS(payload)
        case "tIME":
            parseTIME(payload)
        case "tEXt":
            parseTEXT(payload)
        case "zTXt":
            parseZTXT(payload)
        case "iTXt":
            parseITXT(payload)
        default:
            break
        }
    }

    private mutating func parseIHDR(_ range: Range<Int>) {
        guard range.count == 13 else {
            warnings.append(.invalidChunk(type: "IHDR"))
            return
        }
        let limit = range.upperBound
        var cursor = range.lowerBound
        guard let width = readU32(at: &cursor, limit: limit),
              let height = readU32(at: &cursor, limit: limit),
              let bitDepth = readU8(at: &cursor, limit: limit),
              let colorType = readU8(at: &cursor, limit: limit),
              let compression = readU8(at: &cursor, limit: limit),
              let filter = readU8(at: &cursor, limit: limit),
              let interlace = readU8(at: &cursor, limit: limit)
        else {
            warnings.append(.invalidChunk(type: "IHDR"))
            return
        }
        image = PNGImageInfo(
            width: Int(width),
            height: Int(height),
            bitDepth: Int(bitDepth),
            colorType: Int(colorType),
            compression: Int(compression),
            filter: Int(filter),
            interlace: Int(interlace)
        )
    }

    private mutating func parsePHYS(_ range: Range<Int>) {
        guard range.count == 9 else {
            warnings.append(.invalidChunk(type: "pHYs"))
            return
        }
        let limit = range.upperBound
        var cursor = range.lowerBound
        guard let x = readU32(at: &cursor, limit: limit),
              let y = readU32(at: &cursor, limit: limit),
              let unit = readU8(at: &cursor, limit: limit)
        else {
            warnings.append(.invalidChunk(type: "pHYs"))
            return
        }
        let unitIsMeter = unit == 1
        physical = PNGPhysical(
            pixelsPerUnitX: Int(x),
            pixelsPerUnitY: Int(y),
            unitIsMeter: unitIsMeter,
            dpiX: unitIsMeter ? Double(x) * 0.0254 : nil,
            dpiY: unitIsMeter ? Double(y) * 0.0254 : nil
        )
    }

    private mutating func parseTIME(_ range: Range<Int>) {
        guard range.count == 7 else {
            warnings.append(.invalidChunk(type: "tIME"))
            return
        }
        let limit = range.upperBound
        var cursor = range.lowerBound
        guard let year = readU16(at: &cursor, limit: limit),
              let month = readU8(at: &cursor, limit: limit),
              let day = readU8(at: &cursor, limit: limit),
              let hour = readU8(at: &cursor, limit: limit),
              let minute = readU8(at: &cursor, limit: limit),
              let second = readU8(at: &cursor, limit: limit)
        else {
            warnings.append(.invalidChunk(type: "tIME"))
            return
        }
        guard (1...12).contains(month),
              (1...31).contains(day),
              hour <= 23,
              minute <= 59,
              second <= 60
        else {
            warnings.append(.invalidChunk(type: "tIME"))
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = Int(year)
        components.month = Int(month)
        components.day = Int(day)
        components.hour = Int(hour)
        components.minute = Int(minute)
        components.second = Int(second)
        guard let date = calendar.date(from: components),
              calendar.component(.year, from: date) == Int(year),
              calendar.component(.month, from: date) == Int(month),
              calendar.component(.day, from: date) == Int(day)
        else {
            warnings.append(.invalidChunk(type: "tIME"))
            return
        }
        modificationTime = date
    }

    private mutating func parseTEXT(_ range: Range<Int>) {
        var cursor = range.lowerBound
        guard let keyword = latin1CString(in: range, cursor: &cursor) else {
            warnings.append(.invalidChunk(type: "tEXt"))
            return
        }
        let text = latin1(data[cursor..<range.upperBound])
        appendText(kind: .text, keyword: keyword, text: text, language: "", translatedKeyword: "")
    }

    private mutating func parseZTXT(_ range: Range<Int>) {
        var cursor = range.lowerBound
        guard let keyword = latin1CString(in: range, cursor: &cursor) else {
            warnings.append(.invalidChunk(type: "zTXt"))
            return
        }
        guard let method = readU8(at: &cursor, limit: range.upperBound) else {
            warnings.append(.invalidChunk(type: "zTXt"))
            return
        }
        guard method == 0 else {
            warnings.append(.unsupportedCompression(kind: .compressed, keyword: keyword))
            return
        }
        guard let inflated = inflate(Data(data[cursor..<range.upperBound]), kind: .compressed, keyword: keyword) else {
            return
        }
        appendText(
            kind: .compressed,
            keyword: keyword,
            text: latin1(inflated),
            language: "",
            translatedKeyword: ""
        )
    }

    private mutating func parseITXT(_ range: Range<Int>) {
        var cursor = range.lowerBound
        guard let keyword = latin1CString(in: range, cursor: &cursor) else {
            warnings.append(.invalidChunk(type: "iTXt"))
            return
        }
        guard let flag = readU8(at: &cursor, limit: range.upperBound),
              let method = readU8(at: &cursor, limit: range.upperBound)
        else {
            warnings.append(.invalidChunk(type: "iTXt"))
            return
        }
        guard let language = latin1CString(in: range, cursor: &cursor) else {
            warnings.append(.invalidChunk(type: "iTXt"))
            return
        }
        guard let translated = utf8CString(in: range, cursor: &cursor, kind: .international, keyword: keyword) else {
            warnings.append(.invalidChunk(type: "iTXt"))
            return
        }
        let raw = Data(data[cursor..<range.upperBound])
        let textData: Data
        if flag == 0 {
            textData = raw
        } else if flag == 1 && method == 0 {
            guard let inflated = inflate(raw, kind: .international, keyword: keyword) else { return }
            textData = inflated
        } else {
            warnings.append(.unsupportedCompression(kind: .international, keyword: keyword))
            return
        }
        appendText(
            kind: .international,
            keyword: keyword,
            text: utf8(textData, kind: .international, keyword: keyword),
            language: language,
            translatedKeyword: translated
        )
    }

    private mutating func appendText(
        kind: PNGText.Kind,
        keyword: String,
        text: String,
        language: String,
        translatedKeyword: String
    ) {
        texts.append(
            PNGText(
                index: texts.count,
                kind: kind,
                keyword: keyword,
                text: text,
                language: language,
                translatedKeyword: translatedKeyword
            )
        )
    }

    private mutating func inflate(_ compressed: Data, kind: PNGText.Kind, keyword: String) -> Data? {
        do {
            return try zlibDecompress(compressed)
        } catch {
            warnings.append(.inflateFailed(kind: kind, keyword: keyword))
            return nil
        }
    }

    private mutating func readU32() throws -> UInt32 {
        guard let value = readU32(at: &index, limit: data.count) else { throw PNGError.truncated }
        return value
    }

    private func readU32(at cursor: inout Int, limit: Int) -> UInt32? {
        guard cursor >= 0, cursor + 4 <= limit else { return nil }
        let value = (UInt32(data[cursor]) &<< 24)
            | (UInt32(data[cursor + 1]) &<< 16)
            | (UInt32(data[cursor + 2]) &<< 8)
            | UInt32(data[cursor + 3])
        cursor += 4
        return value
    }

    private func readU16(at cursor: inout Int, limit: Int) -> UInt16? {
        guard cursor >= 0, cursor + 2 <= limit else { return nil }
        let value = (UInt16(data[cursor]) &<< 8) | UInt16(data[cursor + 1])
        cursor += 2
        return value
    }

    private func readU8(at cursor: inout Int, limit: Int) -> UInt8? {
        guard cursor >= 0, cursor < limit else { return nil }
        let value = data[cursor]
        cursor += 1
        return value
    }

    private mutating func readType() -> String? {
        guard index + 4 <= data.count else { return nil }
        let bytes = data[index..<(index + 4)]
        index += 4
        return String(data: bytes, encoding: .ascii) ?? "????"
    }

    private func latin1CString(in range: Range<Int>, cursor: inout Int) -> String? {
        guard cursor <= range.upperBound else { return nil }
        guard let end = data[cursor..<range.upperBound].firstIndex(of: 0) else { return nil }
        let text = latin1(data[cursor..<end])
        cursor = end + 1
        return text
    }

    private func latin1(_ bytes: Data) -> String {
        String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    private mutating func utf8CString(
        in range: Range<Int>,
        cursor: inout Int,
        kind: PNGText.Kind,
        keyword: String
    ) -> String? {
        guard cursor <= range.upperBound else { return nil }
        guard let end = data[cursor..<range.upperBound].firstIndex(of: 0) else { return nil }
        let text = utf8(Data(data[cursor..<end]), kind: kind, keyword: keyword)
        cursor = end + 1
        return text
    }

    private mutating func utf8(_ bytes: Data, kind: PNGText.Kind, keyword: String) -> String {
        if let text = String(data: bytes, encoding: .utf8) {
            return text
        }
        warnings.append(.invalidUTF8(kind: kind, keyword: keyword))
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum PNGCRC {
    static func hash(data: Data, range: Range<Int>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        guard range.lowerBound >= 0, range.upperBound <= data.count else {
            return crc ^ 0xFFFF_FFFF
        }
        for offset in range {
            let entry = Int((crc ^ UInt32(data[offset])) & 0xFF)
            crc = table[entry] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = 0xEDB8_8320 ^ (crc >> 1)
            } else {
                crc >>= 1
            }
        }
        return crc
    }
}

/// PNG の zTXt / 圧縮 iTXt は zlib ラッパー（RFC 1950）。
private func zlibDecompress(_ compressed: Data) throws -> Data {
    if compressed.isEmpty { throw ZlibError.failed }
    var stream = z_stream()
    let initStatus = inflateInit2_(
        &stream,
        MAX_WBITS,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard initStatus == Z_OK else { throw ZlibError.failed }
    defer { inflateEnd(&stream) }

    var output = Data()
    let chunkSize = 16 * 1024
    let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
    defer { destination.deallocate() }

    let result: Int32 = try compressed.withUnsafeBytes { raw in
        guard let source = raw.bindMemory(to: Bytef.self).baseAddress else {
            throw ZlibError.failed
        }
        stream.next_in = UnsafeMutablePointer(mutating: source)
        stream.avail_in = uInt(compressed.count)
        while true {
            stream.next_out = destination
            stream.avail_out = uInt(chunkSize)
            let status = inflate(&stream, Z_NO_FLUSH)
            let produced = chunkSize - Int(stream.avail_out)
            if produced > 0 {
                output.append(destination, count: produced)
            }
            switch status {
            case Z_STREAM_END:
                return Z_OK
            case Z_OK:
                if stream.avail_in == 0, produced == 0 {
                    return Z_DATA_ERROR
                }
            default:
                return status
            }
        }
    }
    guard result == Z_OK else { throw ZlibError.failed }
    return output
}

private enum ZlibError: Error {
    case failed
}
