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

    json_targets = (
        (root / "plugins/opl-fleet-agent/plugin.json", ("version",)),
        (root / "plugins/opl-fleet-agent/.codex-plugin/plugin.json", ("version",)),
        (root / "plugins/opl-fleet-agent/tests/fixtures/provider-telemetry.json", ("node", "agent_version")),
    )
    for target_path, key_path in json_targets:
        original = target_path.read_text(encoding="utf-8")
        payload = json.loads(original)
        node = payload
        for key in key_path[:-1]:
            node = node[key]
        if node[key_path[-1]] != version:
            node[key_path[-1]] = version
            updates[target_path] = original, json.dumps(payload, indent=2) + "\n"

    for path, (original, updated) in updates.items():
        if updated != original:
            path.write_text(updated, encoding="utf-8")


if __name__ == "__main__":
    main()
