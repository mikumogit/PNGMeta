import Foundation
import Testing
import zlib

@testable import PNGMetaCore

struct PNGChunksTests {
    @Test func iendChecksum() {
        let type = Data("IEND".utf8)
        #expect(PNGCRC.hash(data: type, range: 0..<type.count) == 0xAE42_6082)
    }

    @Test func rejectsNonPNGAndTruncatedFiles() {
        #expect(throws: PNGError.notPNG) {
            try parsePNG(Data("nope".utf8))
        }
        var truncated = pngSignature
        truncated.append(contentsOf: [0, 0, 0, 10])
        #expect(throws: PNGError.truncated) {
            try parsePNG(truncated)
        }
    }

    @Test func readsBuiltInChunks() throws {
        var data = pngSignature
        data.append(pngChunk("IHDR", ihdr(width: 2, height: 3)))
        data.append(pngChunk("pHYs", phys(x: 2835, y: 5669, unit: 1)))
        data.append(pngChunk("tEXt", textPayload(keyword: "Café", text: "ok")))
        data.append(pngChunk("zTXt", try ztextPayload(keyword: "parameters", text: "a cat")))
        data.append(pngChunk("iTXt", try itextPayload(keyword: "Author", text: "山田", language: "ja", translated: "作者")))
        data.append(pngChunk("tIME", timePayload(year: 2026, month: 11, day: 1, hour: 18, minute: 30, second: 0)))
        data.append(pngChunk("IEND", Data()))

        let document = try parsePNG(data)
        #expect(document.image?.width == 2)
        #expect(document.image?.height == 3)
        #expect(document.image?.bitDepth == 8)
        #expect(document.image?.colorType == 2)
        #expect(document.physical?.pixelsPerUnitX == 2835)
        #expect(document.physical?.pixelsPerUnitY == 5669)
        #expect(document.physical?.unitIsMeter == true)
        let dpiX = try #require(document.physical?.dpiX)
        #expect(abs(dpiX - Double(2835) * 0.0254) < 0.000_000_1)

        let comment = try #require(document.texts.first { $0.keyword == "Café" })
        #expect(comment.text == "ok")
        #expect(comment.kind == .text)

        let parameters = try #require(document.texts.first { $0.keyword == "parameters" })
        #expect(parameters.text == "a cat")
        #expect(parameters.kind == .compressed)

        let author = try #require(document.texts.first { $0.keyword == "Author" })
        #expect(author.text == "山田")
        #expect(author.language == "ja")
        #expect(author.translatedKeyword == "作者")
        #expect(document.warnings.isEmpty)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let date = try #require(document.modificationTime)
        #expect(calendar.component(.hour, from: date) == 18)
        #expect(calendar.component(.minute, from: date) == 30)
    }

    @Test func fixtureMatchesPythonZlib() throws {
        let document = try parsePNG(try fixtureData())
        let crcOK = document.chunks.allSatisfy { (chunk: PNGChunkRecord) -> Bool in
            chunk.crcOK
        }
        #expect(crcOK)
        #expect(document.warnings.isEmpty)
        #expect(document.chunks.map(\.type) == ["IHDR", "pHYs", "tEXt", "zTXt", "iTXt", "iTXt", "tIME", "IDAT", "IEND"])
        #expect(document.image?.width == 1)
        #expect(document.image?.height == 1)
        #expect(document.image?.colorType == 2)
        #expect(document.image?.interlace == 0)
        let dpiX = try #require(document.physical?.dpiX)
        #expect(abs(dpiX - Double(2835) * 0.0254) < 0.000_000_1)

        let comment = try #require(document.texts.first { $0.keyword == "Comment" })
        #expect(comment.text == "hello png meta")
        #expect(comment.kind == .text)

        let parameters = try #require(document.texts.first { $0.keyword == "parameters" })
        #expect(parameters.text == "steps: 20, sampler: Euler a, prompt: a cat")
        #expect(parameters.kind == .compressed)

        let author = try #require(document.texts.first { $0.keyword == "Author" })
        #expect(author.text == "山田")
        #expect(author.language == "ja")
        #expect(author.translatedKeyword == "作者")

        let description = try #require(document.texts.first { $0.keyword == "Description" })
        #expect(description.text == "赤い点")
        #expect(description.kind == .international)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let date = try #require(document.modificationTime)
        #expect(calendar.component(.year, from: date) == 2026)
        #expect(calendar.component(.month, from: date) == 11)
        #expect(calendar.component(.day, from: date) == 1)
        #expect(calendar.component(.hour, from: date) == 18)
        #expect(calendar.component(.minute, from: date) == 0)
    }

    @Test func crcMismatchStillReadsText() throws {
        var chunk = pngChunk("tEXt", textPayload(keyword: "Comment", text: "still here"))
        let last = chunk.index(before: chunk.endIndex)
        chunk[last] = chunk[last] ^ 0xFF
        var data = pngSignature
        data.append(chunk)
        data.append(pngChunk("IEND", Data()))

        let document = try parsePNG(data)
        #expect(document.texts.first?.text == "still here")
        #expect(document.chunks.first?.crcOK == false)
        #expect(document.warnings.contains(.crcMismatch(type: "tEXt", index: 0)))
    }

    @Test func invalidChunksWarnWithoutStopping() throws {
        var data = pngSignature
        data.append(pngChunk("IHDR", Data([1, 2, 3])))
        var weird = Data("Weird".utf8)
        weird.append(0)
        weird.append(9)
        weird.append(contentsOf: [1, 2, 3])
        data.append(pngChunk("zTXt", weird))
        data.append(pngChunk("IEND", Data()))

        let document = try parsePNG(data)
        #expect(document.image == nil)
        #expect(document.warnings.contains(.invalidChunk(type: "IHDR")))
        #expect(document.warnings.contains(.unsupportedCompression(kind: .compressed, keyword: "Weird")))
        let hasWeird = document.texts.contains { (item: PNGText) -> Bool in
            item.keyword == "Weird"
        }
        #expect(!hasWeird)
    }
}

private let pngSignature = Data([137, 80, 78, 71, 13, 10, 26, 10])

private func fixtureData() throws -> Data {
    let root = try #require(Bundle.module.resourceURL)
    let candidates = [
        root.appending(path: "Fixtures/sample.png"),
        root.appending(path: "sample.png"),
    ]
    let url = try #require(candidates.first { FileManager.default.fileExists(atPath: $0.path) })
    return try Data(contentsOf: url)
}

private func pngChunk(_ type: String, _ payload: Data) -> Data {
    var body = Data(type.utf8)
    body.append(payload)
    var output = Data()
    output.append(be32(UInt32(payload.count)))
    output.append(body)
    output.append(be32(PNGCRC.hash(data: body, range: 0..<body.count)))
    return output
}

private func be32(_ value: UInt32) -> Data {
    withUnsafeBytes(of: value.bigEndian) { Data($0) }
}

private func ihdr(width: UInt32, height: UInt32) -> Data {
    var payload = Data()
    payload.append(be32(width))
    payload.append(be32(height))
    payload.append(contentsOf: [8, 2, 0, 0, 0])
    return payload
}

private func phys(x: UInt32, y: UInt32, unit: UInt8) -> Data {
    var payload = Data()
    payload.append(be32(x))
    payload.append(be32(y))
    payload.append(unit)
    return payload
}

private func timePayload(year: UInt16, month: UInt8, day: UInt8, hour: UInt8, minute: UInt8, second: UInt8) -> Data {
    var payload = Data()
    payload.append(withUnsafeBytes(of: year.bigEndian) { Data($0) })
    payload.append(contentsOf: [month, day, hour, minute, second])
    return payload
}

private func textPayload(keyword: String, text: String) -> Data {
    var payload = Data(keyword.data(using: .isoLatin1)!)
    payload.append(0)
    payload.append(Data(text.data(using: .isoLatin1)!))
    return payload
}

private func ztextPayload(keyword: String, text: String) throws -> Data {
    var payload = Data(keyword.data(using: .isoLatin1)!)
    payload.append(0)
    payload.append(0)
    payload.append(try zlibCompress(Data(text.data(using: .isoLatin1)!)))
    return payload
}

private func itextPayload(
    keyword: String,
    text: String,
    language: String,
    translated: String,
    compress: Bool = false
) throws -> Data {
    var payload = Data(keyword.data(using: .isoLatin1)!)
    payload.append(0)
    payload.append(compress ? 1 : 0)
    payload.append(0)
    payload.append(Data(language.utf8))
    payload.append(0)
    payload.append(Data(translated.utf8))
    payload.append(0)
    let body = Data(text.utf8)
    payload.append(compress ? try zlibCompress(body) : body)
    return payload
}

private func zlibCompress(_ data: Data) throws -> Data {
    let bound = compressBound(uLong(data.count))
    var compressed = Data(count: Int(bound))
    var length = uLongf(bound)
    let status = compressed.withUnsafeMutableBytes { destination in
        data.withUnsafeBytes { source in
            compress(
                destination.bindMemory(to: Bytef.self).baseAddress,
                &length,
                source.bindMemory(to: Bytef.self).baseAddress,
                uLong(data.count)
            )
        }
    }
    guard status == Z_OK else {
        throw ZlibCompressError.failed
    }
    compressed.removeSubrange(Int(length)..<compressed.count)
    return compressed
}

private enum ZlibCompressError: Error {
    case failed
}
