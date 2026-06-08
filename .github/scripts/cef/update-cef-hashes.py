#!/usr/bin/env python3
"""Update the CEF dependency hashes in CMakePresets.json from built artifacts.

Given a directory of CEF distribution artifacts (the *.tar.xz / *.zip produced
by build-cef.sh / Build-CEF.ps1, optionally alongside *.sha256 files), this
computes each artifact's SHA-256 and writes it into the `cef.hashes` block of
CMakePresets.json, replacing the placeholders.

It edits the file textually (not via json.dump) so the diff stays minimal and
the existing formatting is preserved.

Artifact file name -> CMakePresets hash key mapping:
    cef_binary_<ver>_windows_x64_v<r>.zip      -> windows-x64
    cef_binary_<ver>_windows_arm64_v<r>.zip    -> windows-arm64
    cef_binary_<ver>_macos_x86_64_v<r>.tar.xz  -> macos-x86_64
    cef_binary_<ver>_macos_arm64_v<r>.tar.xz   -> macos-arm64
    cef_binary_<ver>_linux_x86_64_v<r>.tar.xz  -> ubuntu-x86_64
    cef_binary_<ver>_linux_aarch64_v<r>.tar.xz -> ubuntu-aarch64

Usage:
    update-cef-hashes.py --artifacts ./cef-artifacts [--presets CMakePresets.json]
"""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

# (filename token after "<ver>_", CMakePresets key)
TOKEN_TO_KEY = {
    "windows_x64": "windows-x64",
    "windows_arm64": "windows-arm64",
    "macos_x86_64": "macos-x86_64",
    "macos_arm64": "macos-arm64",
    "linux_x86_64": "ubuntu-x86_64",
    "linux_aarch64": "ubuntu-aarch64",
}

ARTIFACT_RE = re.compile(
    r"^cef_binary_\d+_(?P<token>windows_x64|windows_arm64|macos_x86_64|"
    r"macos_arm64|linux_x86_64|linux_aarch64)_v\d+\.(?:tar\.xz|zip)$"
)


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def collect_hashes(artifacts_dir: Path) -> dict[str, str]:
    found: dict[str, str] = {}
    for path in sorted(artifacts_dir.iterdir()):
        match = ARTIFACT_RE.match(path.name)
        if not match:
            continue
        key = TOKEN_TO_KEY[match.group("token")]
        found[key] = sha256_of(path)
        print(f"  {key:16s} {found[key]}  ({path.name})")
    return found


def cef_hashes_span(text: str) -> tuple[int, int]:
    """Return the (start, end) character span of the cef `hashes` object body."""
    cef = re.search(r'"cef"\s*:\s*\{', text)
    if not cef:
        raise SystemExit('Could not find a "cef" block in CMakePresets.json')
    hashes = re.search(r'"hashes"\s*:\s*\{', text[cef.end():])
    if not hashes:
        raise SystemExit('Could not find the cef "hashes" object')
    body_start = cef.end() + hashes.end()
    depth = 1
    for i in range(body_start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return body_start, i
    raise SystemExit('Unterminated cef "hashes" object')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", required=True, type=Path,
                        help="Directory containing the built CEF artifacts")
    parser.add_argument("--presets", type=Path, default=Path("CMakePresets.json"))
    args = parser.parse_args()

    print(f"Scanning {args.artifacts} for CEF artifacts...")
    hashes = collect_hashes(args.artifacts)
    if not hashes:
        print("No CEF artifacts matched the expected naming pattern.", file=sys.stderr)
        return 1

    text = args.presets.read_text()
    start, end = cef_hashes_span(text)
    body = text[start:end]

    missing = []
    for key, value in hashes.items():
        pattern = re.compile(rf'("{re.escape(key)}"\s*:\s*")[^"]*(")')
        body, n = pattern.subn(rf"\g<1>{value}\g<2>", body)
        if n == 0:
            missing.append(key)

    if missing:
        print(f"WARNING: keys not present in cef.hashes: {', '.join(missing)}",
              file=sys.stderr)

    args.presets.write_text(text[:start] + body + text[end:])
    print(f"Updated {len(hashes) - len(missing)} hash(es) in {args.presets}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
