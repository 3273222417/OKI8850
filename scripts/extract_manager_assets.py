#!/usr/bin/env python3
"""Extract valid rolling Manager APK links from a release page."""

from __future__ import annotations

import html
import re
import sys
from urllib.parse import unquote, urljoin, urlsplit


DOWNLOAD_LINK = re.compile(
    r"(?i)(?:https?://|/)[^\"'<>\s]+/-/releases/download/[^\"'<>\s]+"
)
RELEASE_APK = re.compile(r"(?i)release\.apk$")
EXCLUDED_APK = re.compile(r"(?i)(?:debug|spoofed)")


def extract_assets(document: str, base_url: str, expected_version: str) -> list[tuple[str, str]]:
    """Return APKs sorted by preferred architecture and then filename."""

    base = urlsplit(base_url)
    if base.scheme not in {"http", "https"} or not base.netloc:
        raise ValueError("base URL must be an absolute HTTP(S) URL")
    release_marker = "/-/releases/tag/"
    if release_marker not in base.path:
        raise ValueError("base URL must point to a release tag")
    repository_path, tag = base.path.rsplit(release_marker, 1)
    if not repository_path or not tag or "/" in tag:
        raise ValueError("base URL has an invalid release tag path")
    download_prefix = f"{repository_path}/-/releases/download/{tag}/"

    # CNB embeds the release state as JSON in the page. Decode HTML entities
    # and escaped slashes before scanning both hrefs and embedded JSON paths.
    document = html.unescape(document).replace("\\/", "/")
    found: dict[tuple[str, str], int] = {}
    for match in DOWNLOAD_LINK.finditer(document):
        raw_url = match.group(0).rstrip(".,;:)]}\\")
        absolute = urljoin(base_url, raw_url)
        parsed = urlsplit(absolute)
        if (
            parsed.scheme not in {"http", "https"}
            or parsed.netloc != base.netloc
            or not parsed.path.startswith(download_prefix)
        ):
            continue
        name = unquote(parsed.path.rsplit("/", 1)[-1])
        if not RELEASE_APK.search(name) or EXCLUDED_APK.search(name):
            continue
        if not re.search(rf"_{re.escape(expected_version)}(?:-[A-Za-z0-9-]+)?-release\.apk$", name, re.I):
            continue
        if re.search(r"(?i)arm64-v8a", name):
            rank = 0
        elif re.search(r"(?i)universal", name):
            rank = 1
        else:
            continue
        found.setdefault((name, absolute), rank)

    return [item for item, _ in sorted(found.items(), key=lambda entry: (entry[1], entry[0][0], entry[0][1]))]


def main() -> int:
    if len(sys.argv) != 3 or not re.fullmatch(r"[0-9]+", sys.argv[2]):
        print(f"usage: {sys.argv[0]} BASE_URL EXPECTED_VERSION", file=sys.stderr)
        return 2
    for name, url in extract_assets(sys.stdin.read(), sys.argv[1], sys.argv[2]):
        print(f"{name}\t{url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
