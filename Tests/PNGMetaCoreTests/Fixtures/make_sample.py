#!/usr/bin/env python3
"""zlib で圧縮した tEXt / zTXt / iTXt を含む 1x1 PNG を作る。"""

import struct
import zlib
from pathlib import Path


def chunk(tag: bytes, data: bytes) -> bytes:
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)


def text_chunk(keyword: str, text: str) -> bytes:
    payload = keyword.encode("latin-1") + b"\x00" + text.encode("latin-1")
    return chunk(b"tEXt", payload)


def ztext_chunk(keyword: str, text: str) -> bytes:
    payload = keyword.encode("latin-1") + b"\x00" + b"\x00" + zlib.compress(text.encode("latin-1"))
    return chunk(b"zTXt", payload)


def itext_chunk(keyword: str, text: str, language: str = "", translated: str = "", compress: bool = False) -> bytes:
    body = text.encode("utf-8")
    if compress:
        body = zlib.compress(body)
    payload = (
        keyword.encode("latin-1")
        + b"\x00"
        + bytes([1 if compress else 0, 0])
        + language.encode("ascii")
        + b"\x00"
        + translated.encode("utf-8")
        + b"\x00"
        + body
    )
    return chunk(b"iTXt", payload)


png = b"".join(
    [
        b"\x89PNG\r\n\x1a\n",
        chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)),
        chunk(b"pHYs", struct.pack(">IIB", 2835, 2835, 1)),
        text_chunk("Comment", "hello png meta"),
        ztext_chunk("parameters", "steps: 20, sampler: Euler a, prompt: a cat"),
        itext_chunk("Author", "山田", language="ja", translated="作者"),
        itext_chunk("Description", "赤い点", compress=True),
        chunk(b"tIME", struct.pack(">HBBBBB", 2026, 11, 1, 18, 0, 0)),
        chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00")),
        chunk(b"IEND", b""),
    ]
)

destination = Path(__file__).with_name("sample.png")
destination.write_bytes(png)
print(f"{destination} {len(png)} bytes")
