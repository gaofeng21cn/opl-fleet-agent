"""Align provider release fallbacks and the shared telemetry fixture."""

import json
import plistlib
import re
from pathlib import Path


def updated_declaration(path, pattern, version):
    original = path.read_text(encoding="utf-8")
    updated, count = re.subn(pattern, lambda match: match[1] + version + match[2], original)
    if count != 1:
        raise SystemExit(f"Expected one provider version declaration in {path.name}.")
    return original, updated


def main():
    root = Path(__file__).resolve().parents[1]
    with (root / "Resources/Info.plist").open("rb") as plist:
        version = plistlib.load(plist)["CFBundleShortVersionString"]
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise SystemExit("The Fleet Agent bundle must declare a numeric release version.")

    declarations = {
        root / "Sources/OPLFleetAgentCore/FleetAgentProtocol.swift": (
            r'(?m)^( *public static let defaultAgentVersion = ")[^"\n]*(")$'
        ),
        root / "windows/src/OPLFleetAgent.Core/AmbientOps.cs": (
            r'(?m)^( *public const string DefaultAgentVersion = ")[^"\n]*(";)$'
        ),
    }
    updates = {
        path: updated_declaration(path, pattern, version)
        for path, pattern in declarations.items()
    }

    fixture = root / "plugins/opl-fleet-agent/tests/fixtures/provider-telemetry.json"
    original = fixture.read_text(encoding="utf-8")
    telemetry = json.loads(original)
    if telemetry["node"]["agent_version"] != version:
        telemetry["node"]["agent_version"] = version
        updates[fixture] = original, json.dumps(telemetry, indent=2) + "\n"

    for path, (original, updated) in updates.items():
        if updated != original:
            path.write_text(updated, encoding="utf-8")


if __name__ == "__main__":
    main()
