#!/usr/bin/env python3
"""Verify the embedded IKCONFIG of an uncompressed arm64 kernel Image."""

import argparse
import hashlib
from pathlib import Path
import zlib


START = b"IKCFG_ST"
END = b"IKCFG_ED"
GZIP_HEADER = b"\x1f\x8b\x08"
MAX_CONFIG_BYTES = 4 * 1024 * 1024
GZIP_OVERHEAD_ALLOWANCE = 64 * 1024


def embedded_config(image: bytes) -> bytes:
    if image[56:60] != b"ARM\x64":
        raise ValueError("expected an uncompressed arm64 Image")

    config = None
    offset = 0
    view = memoryview(image)
    while (start := image.find(START + GZIP_HEADER, offset)) >= 0:
        offset = start + len(START)
        limit = offset + MAX_CONFIG_BYTES + GZIP_OVERHEAD_ALLOWANCE + len(END)
        decoder = zlib.decompressobj(wbits=16 + zlib.MAX_WBITS)
        try:
            payload = decoder.decompress(view[offset:limit], MAX_CONFIG_BYTES + 1)
        except zlib.error:
            continue
        # Locate the end marker after the gzip trailer, not inside the stream.
        if not (0 < len(payload) <= MAX_CONFIG_BYTES and decoder.eof and decoder.unused_data.startswith(END)):
            continue
        if config is not None:
            raise ValueError("multiple embedded IKCONFIG records")
        config = payload

    if config is None:
        raise ValueError("no valid embedded IKCONFIG record")
    return config


def verify(image: Path, expected: Path) -> None:
    embedded = embedded_config(image.read_bytes())
    expected_bytes = expected.read_bytes()
    if embedded == expected_bytes:
        return

    embedded_lines = embedded.splitlines()
    expected_lines = expected_bytes.splitlines()
    line_number = next(
        (index + 1 for index, (left, right) in enumerate(zip(embedded_lines, expected_lines))
         if left != right),
        min(len(embedded_lines), len(expected_lines)) + 1,
    )
    embedded_line = embedded_lines[line_number - 1] if line_number <= len(embedded_lines) else b"<EOF>"
    expected_line = expected_lines[line_number - 1] if line_number <= len(expected_lines) else b"<EOF>"
    raise ValueError(
        f"embedded IKCONFIG in {image} differs from {expected}; "
        f"first differing line {line_number}: image={embedded_line!r}, "
        f"evidence={expected_line!r}; "
        f"sizes image={len(embedded)} evidence={len(expected_bytes)}; "
        f"sha256 image={hashlib.sha256(embedded).hexdigest()} "
        f"evidence={hashlib.sha256(expected_bytes).hexdigest()}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("config", type=Path)
    args = parser.parse_args()
    try:
        verify(args.image, args.config)
    except (OSError, ValueError) as exc:
        parser.exit(1, f"Image configuration check failed: {exc}\n")
    print("Image IKCONFIG matches the final build configuration.")


if __name__ == "__main__":
    main()
