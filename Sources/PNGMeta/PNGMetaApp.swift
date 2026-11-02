import AppKit
import ImageIO
import PNGMetaCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct PNGMetaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("PNG Meta", id: "main") {
            ContentView()
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("開く…") {
                    AppModel.shared.showImporter = true
                }
                .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        let paths = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("/") || $0.hasPrefix(".") }
        if let path = paths.last {
            AppModel.shared.load(url: URL(fileURLWithPath: path))
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.last else { return }
        AppModel.shared.load(url: url)
        application.activate()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        AppModel.shared.load(url: URL(fileURLWithPath: filename))
        sender.activate()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@MainActor
final class WindowChrome: ObservableObject {
    @Published var targeted = false
    @Published var preview: NSImage?
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var fileURL: URL?
    @Published var fileName = ""
    @Published var document: PNGDocument?
    @Published var imageData: Data?
    @Published var sections: [MetaSection] = []
    @Published var errorText: String?
    @Published var showImporter = false

    private init() {}

    func load(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        fileURL = url
        fileName = url.lastPathComponent
        do {
            let data = try Data(contentsOf: url)
            document = try parsePNG(data)
            imageData = data
            sections = ImageMetadata.sections(of: url)
            errorText = nil
        } catch let error as PNGError {
            clearContent()
            errorText = Self.message(for: error)
        } catch {
            clearContent()
            errorText = error.localizedDescription
        }
        updateWindowTitle()
    }

    func updateWindowTitle() {
        let window = NSApp.keyWindow ?? NSApp.windows.first
        window?.title = fileName.isEmpty ? "PNG Meta" : fileName
        window?.representedURL = fileURL
    }

    private func clearContent() {
        document = nil
        imageData = nil
        sections = []
    }

    private static func message(for error: PNGError) -> String {
        switch error {
        case .notPNG:
            return "PNGではありません。"
        case .truncated:
            return "ファイルが途中で切れています。"
        }
    }
}

struct MetaField: Identifiable {
    let id = UUID()
    var key: String
    var value: String
}

struct MetaSection: Identifiable {
    let id = UUID()
    var title: String
    var fields: [MetaField]
}

enum ImageMetadata {
    static func sections(of url: URL) -> [MetaSection] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        else {
            return []
        }
        return sections(from: properties)
    }

    private static func sections(from properties: CFDictionary) -> [MetaSection] {
        guard let root = asDictionary(properties) else { return [] }
        var scalars: [MetaField] = []
        var nested: [MetaSection] = []
        for key in root.keys.sorted(by: { stringKey($0) < stringKey($1) }) {
            guard let value = root[key] else { continue }
            let name = stringKey(key)
            if let child = asDictionary(value) {
                let fields = flatten(child)
                if !fields.isEmpty {
                    nested.append(MetaSection(title: sectionTitle(name), fields: fields))
                }
            } else if let text = format(value) {
                scalars.append(MetaField(key: name, value: text))
            }
        }
        var result: [MetaSection] = []
        if !scalars.isEmpty {
            result.append(MetaSection(title: "ImageIO", fields: scalars))
        }
        result.append(contentsOf: nested)
        return result
    }

    private static func flatten(_ dictionary: [AnyHashable: Any], prefix: String = "") -> [MetaField] {
        var fields: [MetaField] = []
        for key in dictionary.keys.sorted(by: { stringKey($0) < stringKey($1) }) {
            guard let value = dictionary[key] else { continue }
            let name = stringKey(key)
            let label = prefix.isEmpty ? name : "\(prefix).\(name)"
            if let child = asDictionary(value) {
                fields.append(contentsOf: flatten(child, prefix: label))
            } else if let text = format(value) {
                fields.append(MetaField(key: label, value: text))
            }
        }
        return fields
    }

    private static func asDictionary(_ value: Any) -> [AnyHashable: Any]? {
        if let dictionary = value as? [AnyHashable: Any] {
            return dictionary
        }
        guard let dictionary = value as? NSDictionary else { return nil }
        var result: [AnyHashable: Any] = [:]
        for (key, entry) in dictionary {
            guard let key = key as? AnyHashable else { continue }
            result[key] = entry
        }
        return result
    }

    private static func stringKey(_ key: AnyHashable) -> String {
        if let text = key as? String { return text }
        if let text = key.base as? String { return text }
        return String(describing: key)
    }

    private static func sectionTitle(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        switch trimmed {
        case "Exif":
            return "EXIF"
        case "TIFF":
            return "TIFF"
        case "GPS":
            return "GPS"
        case "IPTC":
            return "IPTC"
        case "PNG":
            return "PNG"
        default:
            return trimmed
        }
    }

    private static func format(_ value: Any) -> String? {
        if value is NSDictionary || value is [AnyHashable: Any] {
            return nil
        }
        if let data = value as? Data {
            return "\(data.count) バイト"
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "はい" : "いいえ"
            }
            return number.stringValue
        }
        if let text = value as? String {
            return text
        }
        if let date = value as? Date {
            return utcFormatter.string(from: date)
        }
        if let array = value as? [Any] {
            return array.compactMap(format).joined(separator: ", ")
        }
        let text = String(describing: value)
        if text.count > 4000 {
            return String(text.prefix(4000)) + "…"
        }
        return text
    }

    private static let utcFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter
    }()
}

struct ContentView: View {
    @ObservedObject private var model = AppModel.shared
    @StateObject private var chrome = WindowChrome()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            bodyContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 480)
        .onDrop(of: [.fileURL], isTargeted: $chrome.targeted, perform: handleDrop)
        .overlay {
            if chrome.targeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.png]) { result in
            switch result {
            case .success(let url):
                model.load(url: url)
            case .failure(let error):
                guard !isCancellation(error) else { return }
                model.errorText = error.localizedDescription
            }
        }
        .onAppear {
            refreshPreview()
            model.updateWindowTitle()
        }
        .onOpenURL { url in
            model.load(url: url)
        }
        .onChange(of: model.imageData) { _, _ in
            refreshPreview()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(model.fileName.isEmpty ? "ファイル未選択" : model.fileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("開く…") {
                model.showImporter = true
            }
            .accessibilityIdentifier("openButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var bodyContent: some View {
        if let document = model.document {
            HSplitView {
                previewPane
                details(document)
            }
        } else if let errorText = model.errorText {
            ContentUnavailableView {
                Label("読み込めません", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorText)
            }
        } else {
            ContentUnavailableView {
                Label("PNGをドロップ", systemImage: "photo")
            } description: {
                Text("ウィンドウにファイルをドロップするか、開くを押してください。")
            }
        }
    }

    private var previewPane: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let preview = chrome.preview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .padding(24)
                    .accessibilityLabel("プレビュー")
            } else {
                Text("プレビューできません")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func details(_ document: PNGDocument) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !document.warnings.isEmpty {
                    section("注意") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(document.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warningText(warning))
                                    .foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                section("画像") {
                    imageFields(document)
                }
                section("テキスト") {
                    if document.texts.isEmpty {
                        Text("テキストチャンクはありません")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(document.texts) { item in
                                textCard(item)
                            }
                        }
                    }
                }
                ForEach(model.sections) { meta in
                    section(meta.title) {
                        fieldGrid(meta.fields)
                    }
                }
                section("チャンク") {
                    chunkList(document.chunks)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("metadata")
    }

    private func imageFields(_ document: PNGDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let image = document.image {
                fieldGrid([
                    MetaField(key: "幅", value: "\(image.width)"),
                    MetaField(key: "高さ", value: "\(image.height)"),
                    MetaField(key: "ビット深度", value: "\(image.bitDepth)"),
                    MetaField(key: "色", value: colorName(image.colorType)),
                    MetaField(key: "インターレース", value: interlaceName(image.interlace)),
                ])
            } else {
                Text("IHDRがありません")
                    .foregroundStyle(.secondary)
            }
            if let physical = document.physical {
                fieldGrid(physicalFields(physical))
                    .padding(.top, 4)
            }
            if let time = document.modificationTime {
                fieldGrid([
                    MetaField(key: "更新日時", value: utcFormatter.string(from: time)),
                ])
                .padding(.top, 4)
            }
        }
    }

    private func physicalFields(_ physical: PNGPhysical) -> [MetaField] {
        let unit = physical.unitIsMeter ? "ピクセル/メートル" : "ピクセル/単位"
        var fields = [
            MetaField(key: "水平密度", value: "\(physical.pixelsPerUnitX) \(unit)"),
            MetaField(key: "垂直密度", value: "\(physical.pixelsPerUnitY) \(unit)"),
        ]
        if let dpiX = physical.dpiX {
            fields.append(MetaField(key: "水平解像度", value: String(format: "%.2f dpi", dpiX)))
        }
        if let dpiY = physical.dpiY {
            fields.append(MetaField(key: "垂直解像度", value: String(format: "%.2f dpi", dpiY)))
        }
        return fields
    }

    private func textCard(_ item: PNGText) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.keyword.isEmpty ? "（キーワードなし）" : item.keyword)
                    .font(.headline)
                Text(item.kind.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                if !item.language.isEmpty {
                    Text(item.language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("コピー") {
                    copy(item.text)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            if !item.translatedKeyword.isEmpty {
                Text(item.translatedKeyword)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(item.text.isEmpty ? "（空）" : item.text)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("text-\(item.keyword)")
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor))
        }
    }

    private func chunkList(_ chunks: [PNGChunkRecord]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(chunkLines(chunks)) { line in
                HStack(alignment: .firstTextBaseline) {
                    Text(line.type)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(line.detail)
                        .foregroundStyle(.secondary)
                    if !line.crcOK {
                        Text("CRC不一致")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func fieldGrid(_ fields: [MetaField]) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(fields) { field in
                if field.value.count > 160 || field.value.contains("\n") {
                    GridRow {
                        Text(field.key)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(field.value)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    GridRow {
                        Text(field.key)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(field.value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
            content()
        }
    }

    private func refreshPreview() {
        chrome.preview = model.imageData.flatMap { NSImage(data: $0) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
            guard let data else { return }
            let payload = data
            Task { @MainActor in
                guard let url = fileURL(from: payload) else { return }
                AppModel.shared.load(url: url)
            }
        }
        return true
    }
}

private struct ChunkLine: Identifiable {
    var id: String
    var type: String
    var detail: String
    var crcOK: Bool
}

private func chunkLines(_ chunks: [PNGChunkRecord]) -> [ChunkLine] {
    var lines: [ChunkLine] = []
    var index = 0
    while index < chunks.count {
        let chunk = chunks[index]
        if chunk.type == "IDAT" || chunk.type == "fdAT" {
            let type = chunk.type
            var count = 0
            var total = 0
            var crcOK = true
            let start = index
            while index < chunks.count, chunks[index].type == type {
                count += 1
                total += chunks[index].length
                crcOK = crcOK && chunks[index].crcOK
                index += 1
            }
            let detail = count > 1 ? "× \(count)、合計 \(total) バイト" : "\(total) バイト"
            lines.append(ChunkLine(id: "\(type)-\(start)", type: type, detail: detail, crcOK: crcOK))
        } else {
            lines.append(
                ChunkLine(
                    id: "\(chunk.index)",
                    type: chunk.type,
                    detail: "\(chunk.length) バイト",
                    crcOK: chunk.crcOK
                )
            )
            index += 1
        }
    }
    return lines
}

private func colorName(_ colorType: Int) -> String {
    switch colorType {
    case 0:
        return "グレースケール"
    case 2:
        return "カラー"
    case 3:
        return "インデックスカラー"
    case 4:
        return "グレースケール+アルファ"
    case 6:
        return "カラー+アルファ"
    default:
        return "不明 (\(colorType))"
    }
}

private func interlaceName(_ interlace: Int) -> String {
    switch interlace {
    case 0:
        return "なし"
    case 1:
        return "Adam7"
    default:
        return "不明 (\(interlace))"
    }
}

private func warningText(_ warning: PNGWarning) -> String {
    switch warning {
    case .crcMismatch(let type, let index):
        return "\(index + 1)番目の\(type)チャンクはCRCが一致しません。"
    case .inflateFailed(let kind, let keyword):
        return "\(kind.rawValue)「\(keyword)」を展開できませんでした。"
    case .unsupportedCompression(let kind, let keyword):
        return "\(kind.rawValue)「\(keyword)」の圧縮方式には対応していません。"
    case .invalidUTF8(let kind, let keyword):
        return "\(kind.rawValue)「\(keyword)」はUTF-8として解釈できませんでした。"
    case .invalidChunk(let type):
        return "\(type)チャンクの形式が不正です。"
    }
}

private func copy(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

private func fileURL(from data: Data) -> URL? {
    if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
        return url
    }
    guard var text = String(data: data, encoding: .utf8) else { return nil }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    guard !text.isEmpty else { return nil }
    if text.hasPrefix("file:") {
        return URL(string: text)
    }
    if text.hasPrefix("/") {
        return URL(fileURLWithPath: text)
    }
    return nil
}

private func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
}

private let utcFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
    return formatter
}()
