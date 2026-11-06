#!/usr/bin/env python3
"""Classify a tag against the native app and optional Package versions."""

from __future__ import annotations

import json
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SEMVER = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?")


def main() -> int:
    if len(sys.argv) != 5:
        raise SystemExit("usage: release-tag-eligibility.py TAG INFO_PLIST WINDOWS_PROJECT PACKAGE_MANIFEST")

    tag, plist_path, project_path, package_path = sys.argv[1:]
    if not tag.startswith("v") or SEMVER.fullmatch(tag[1:]) is None:
        raise SystemExit(f"Unsupported release tag: {tag}")

    with Path(plist_path).open("rb") as source:
        macos_version = plistlib.load(source).get("CFBundleShortVersionString")
    windows_version = ET.parse(project_path).findtext(".//Version")
    package_manifest = Path(package_path)
    package_version = (
        json.loads(package_manifest.read_text(encoding="utf-8")).get("version")
        if package_manifest.is_file()
        else None
    )

    versions = {"macOS": macos_version, "Windows": windows_version, "Package": package_version}
    for owner, version in versions.items():
        if owner == "Package" and version is None and tag[1:] == macos_version:
            continue
        if not isinstance(version, str) or SEMVER.fullmatch(version) is None:
            raise SystemExit(f"Missing or invalid {owner} version: {version!r}")
    if macos_version != windows_version:
        raise SystemExit(f"Native release versions disagree: macOS={macos_version} Windows={windows_version}")

    tag_version = tag[1:]
    if tag_version == macos_version:
        print("native")
    elif tag_version == package_version:
        print("package-only")
    else:
        raise SystemExit(f"Tag does not match native or Package version: tag={tag_version} native={macos_version} package={package_version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
