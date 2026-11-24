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
node --test plugins/opl-fleet-agent/tests/native-provider-integration.test.mjs
./scripts/build-app.sh
./scripts/build-dmg.sh
```

`build-app.sh` builds the native app, embeds `Sparkle.framework` into
`Contents/Frameworks`, validates Sparkle `SUFeedURL`/`SUPublicEDKey` keys, and
signs Sparkle's nested helpers inside-out before signing the app bundle;
`build-dmg.sh` packages a universal DMG. `generate-appcast.sh` uses Sparkle's
`generate_appcast` and `sign_update --verify` to emit and verify the EdDSA-signed
`appcast.xml` against the notarized DMG.
After `swift test` builds the provider, the native-provider integration test
copies that executable and the optional Package into an isolated temporary
carrier. It reads synthetic telemetry, removes the source, and checks that
telemetry and doctor preserve the same node and last-known sample before
becoming unavailable without a cache. It does not install into the user's
Applications directory or claim signed-release acceptance.
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

[CI](../.github/workflows/ci.yml) runs Swift lint/tests, focused shell checks
(including [sparkle-updater-contract.test.sh](../Tests/sparkle-updater-contract.test.sh)
to enforce the macOS in-app updater contract and signed `appcast.xml` generation),
and Package adapter tests on push and pull request. It does not build or
qualify the Windows installer.

The manually dispatched [Qualification workflow](../.github/workflows/qualification.yml)
owns universal development packaging (including verifying embedded universal
`Sparkle.framework`), plus Windows packaging,
portable installation, installer/uninstaller checks, and installed-version
readback. Its Windows in-app updater transaction runs only on `main`.
Unsigned development artifacts and a successful workflow are not public release
or clean-machine acceptance.

[Release](../.github/workflows/release.yml) owns release assets. Its macOS
release job delegates signing, app/DMG notarization, Ed25519 `appcast.xml`
generation, and release verification to the shared
[reusable macOS Sparkle release workflow](https://github.com/gaofeng21cn/one-person-lab/blob/main/.github/workflows/reusable-macos-sparkle-release.yml).
macOS public assets must use Developer ID, hardened runtime, timestamping, Apple notarization,
a stapled ticket, and an Ed25519-signed Sparkle `appcast.xml` (`SPARKLE_ED25519_PRIVATE_KEY`
matching `SUPublicEDKey` in `Resources/Info.plist`). The workflow fails closed
without protected Apple credentials or the Sparkle Ed25519 signing key. macOS,
Windows and the optional OPL integration share one product
version and one annotated tag. The daily Package publisher updates these
declarations together, waits for this tag's native release workflow, and then
publishes the same-version OCI Package. [verify-release.sh](../scripts/verify-release.sh)
checks final notarized bytes, embedded `Sparkle.framework` signatures,
architectures, Team ID `SVVC4TA784`, checksum, and `appcast.xml` consistency,
and the `readback` job in [Release](../.github/workflows/release.yml) verifies
public release assets (including `appcast.xml`) and checksums anonymously after
publication. The Homebrew Tap consumes this release with `auto_updates true`;
it must not independently define version, checksum, or asset truth.

Windows packaging currently has no Authenticode signing step. SHA-256 and
GitHub provenance do not provide publisher trust or SmartScreen reputation.
Before claiming Windows production readiness, obtain a clean Windows 11
readback covering launch/tray interaction, DPAPI persistence, login startup,
firewall consent/discovery, sleep/network recovery, and accepted Gateway push.
Do not reuse an older version's receipt as current evidence.
