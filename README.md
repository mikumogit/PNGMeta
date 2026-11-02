# PNG Meta

PNGファイルに埋め込まれたメタデータを閲覧する、macOS向けの単一ウィンドウアプリです。

画像生成ツールが書き込むプロンプトやパラメータ、EXIF、寸法、更新日時を確認できます。閲覧専用で、ファイルは変更しません。

## できること

- PNGをウィンドウへドロップする、または「開く…」（⌘O）で選ぶ
- 画像のプレビュー
- 幅、高さ、ビット深度、色、インターレース（IHDR）
- ピクセル密度と dpi（pHYs）
- 更新日時（tIME、UTC）
- テキストチャンクの全文
  - tEXt（Latin-1）
  - zTXt（zlib で圧縮された Latin-1）
  - iTXt（UTF-8。圧縮されている場合は zlib）
- テキストの選択と、項目ごとのコピー
- ImageIO が読む EXIF、TIFF、GPS、IPTC
- その他のチャンクは種類とサイズだけ。IDAT や ICC プロファイルの中身は出しません
- CRC が一致しないチャンクは警告を出したうえで、読める範囲は表示します

## 必要なもの

- macOS 14 以降
- Swift の Command Line Tools。Xcode 本体は不要です

```bash
xcode-select -p
swift --version
```

## ビルドして起動する

```bash
./build.sh
open PNGMeta.app
```

`build.sh` はリリースビルドを作り、アドホック署名した `PNGMeta.app` にまとめます。サンドボックスは付けていません。自分の Mac で使うためのものです。

## テスト

```bash
swift test
```

テスト用の PNG は `Tests/PNGMetaCoreTests/Fixtures/sample.png` です。同じ内容は `Tests/PNGMetaCoreTests/Fixtures/make_sample.py` で作り直せます。

Command Line Tools だけでは Swift Testing のマクロ実装を自動で読まないため、`Package.swift` のテストターゲットはそのプラグインのパスを明示しています。パスは Apple の Command Line Tools にある `libTestingMacros.dylib` です。

## 構成

| パス | 内容 |
| --- | --- |
| `Sources/PNGMetaCore` | PNG チャンクの読み取り |
| `Sources/PNGMeta` | SwiftUI のウィンドウ |
| `build.sh` | `.app` バンドルの作成 |

zTXt と圧縮された iTXt は zlib（RFC 1950）です。展開にはシステムの libz を使っています。
