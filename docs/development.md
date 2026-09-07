# Development and Release Qualification

This guide owns contributor build, test, packaging, and release verification.
Configuration and installed-runtime acceptance belong to [operations](operations.md).

## macOS

Use Swift 6 and a compatible Xcode/macOS toolchain. The deployment target is
macOS 13, as declared by [Package.swift](../Package.swift).

```bash
xcrun swift-format lint --recursive Sources Tests Package.swift
swift test
node --test plugins/opl-fleet-agent/tests/adapter.test.mjs
./scripts/build-app.sh
./scripts/build-dmg.sh
```

`build-app.sh` builds the native app; `build-dmg.sh` packages a universal DMG.
For a development install on the current Mac, run `./scripts/install.sh`.
It builds, ad-hoc signs, installs, and launches; use `--no-launch` to skip launch
or `OPL_FLEET_AGENT_INSTALL_DIR` to choose the destination. This is not a
Developer ID signed or notarized public release.

## Windows

Install the .NET 8 SDK and PowerShell 7. Run from the repository root:

```powershell
pwsh ./windows/scripts/build.ps1 -Runtime win-x64
```

The script restores locked dependencies, runs both Core and Windows UI tests,
and publishes self-contained native UI and provider executables. It emits
`windows/dist/OPL-Fleet-Agent-Windows-win-x64.zip` and the sibling `.sha256`.

Install Inno Setup 6 to build the current-user installer:

```powershell
pwsh ./windows/scripts/build-installer.ps1 -Runtime win-x64
```

This also emits `OPL-Fleet-Agent-Windows-win-x64-Setup.exe` and its checksum in
`windows/dist`. The scripts own the default source version; release automation
passes the version being qualified explicitly. `win-x64` is the current build
target. Windows on Arm can use OS x64 emulation; a native Arm64 build is not a
qualified target.

## Workflow boundaries

[CI](../.github/workflows/ci.yml) runs Swift lint/tests, focused shell checks,
and Package adapter tests on push and pull request. It does not build or
qualify the Windows installer.

The manually dispatched [Qualification workflow](../.github/workflows/qualification.yml)
owns universal development packaging and updater checks, plus Windows packaging,
portable installation, installer/uninstaller checks, and installed-version
readback. Its Windows in-app updater transaction runs only on `main`.
Unsigned development artifacts and a successful workflow are not public release
or clean-machine acceptance.

[Release](../.github/workflows/release.yml) owns release assets. macOS public
assets must use Developer ID, hardened runtime, timestamping, Apple notarization,
and a stapled ticket. The workflow fails closed without protected Apple
credentials. [verify-release.sh](../scripts/verify-release.sh) checks final
notarized bytes, architectures, Team ID `SVVC4TA784`, and checksum. The separate
[public readback workflow](../.github/workflows/release-public-readback.yml)
checks published release evidence. The Homebrew Tap consumes this release;
it must not independently define version, checksum, or asset truth.

Windows packaging currently has no Authenticode signing step. SHA-256 and
GitHub provenance do not provide publisher trust or SmartScreen reputation.
Before claiming Windows production readiness, obtain a clean Windows 11
readback covering launch/tray interaction, DPAPI persistence, login startup,
firewall consent/discovery, sleep/network recovery, and accepted Gateway push.
Do not reuse an older version's receipt as current evidence.
