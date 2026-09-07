# Agent Operations

This guide owns operator configuration and installed-runtime acceptance. Public
installation entry points are in the [README](../README.md); Windows installer,
portable archive, and WSL details are in the [Windows guide](../windows/README.md).

## Choose the input

Verify the selected Codex home contains `sessions` before setting `CODEX_HOME`.
The defaults are `~/.codex` on macOS and `%USERPROFILE%\.codex` on Windows.
Windows Settings can select another home. Native Windows and WSL UNC roots are
separate sources; choose explicitly instead of silently merging or switching.

Inspect the selected source from a macOS source checkout:

```bash
CODEX_HOME=/path/to/codex-home swift run opl-fleet-agent-snapshot --json
```

The optional Framework Package's read-only telemetry and doctor commands are
owned by its [Skill](../plugins/opl-fleet-agent/skills/opl-fleet-agent/SKILL.md).
Do not replace a missing native provider with direct log collection in the plugin.

## Connect a desktop to Fleet Gateway

Gateway integration and discovery are enabled by default on both desktops.
Use Settings to disable them or choose an endpoint, and complete visible device
approval before signed pushes can be accepted. An operator can trigger
rediscovery and help verify the displayed six-digit code; do not approve an
unknown device or extract its private key.
Disable integration from Settings to stop pushes. macOS Direct availability
is a separate transport, described in [architecture](architecture.md).

For a manual connection, macOS accepts a hostname or IP without a scheme. Local
addresses default to HTTP on port `8787`; non-local hosts default to HTTPS.
Explicit HTTP(S) schemes are accepted. The macOS implementation retries a
manual local HTTPS endpoint over HTTP on `URLError.secureConnectionFailed`;
that error does not itself prove the server lacks HTTPS. Windows accepts an
absolute HTTP(S) Gateway URL.

The desktop bearer-token field remains implemented, while signed per-device
pairing is the default setup path. Private keys remain in Keychain on macOS or
current-user DPAPI ciphertext on Windows; the Gateway receives the public key.
Windows settings persist `ProtectedDevicePrivateKey`, never the plaintext key.
An approved device can resume signed pushes across application restarts.

## Run the headless push command

The current headless implementation requires bearer authentication. Set
`OPL_FLEET_AGENT_AMBIENT_URL` for an explicit endpoint; otherwise it discovers
Gateway services. `OPL_FLEET_AGENT_AMBIENT_INSTANCE_ID` prefers one discovered
instance, and an explicit URL takes precedence.

Use a pre-provisioned generic-password Keychain item so the token is not present
in the command line or shell history:

```bash
OPL_FLEET_AGENT_AMBIENT_URL=http://opl-fleet-gateway.local:8787 \
OPL_FLEET_AGENT_AMBIENT_TOKEN_KEYCHAIN_SERVICE=opl-fleet-agent-push \
OPL_FLEET_AGENT_MACHINE_ID=primary-mac \
OPL_FLEET_AGENT_MACHINE_NAME='Primary Mac' \
swift run opl-fleet-agent-headless --once
```

`OPL_FLEET_AGENT_KEYCHAIN_ACCOUNT` overrides the default current-user account.
`OPL_FLEET_AGENT_AMBIENT_TOKEN` is also accepted by the executable, but secrets
must not enter task prompts, repository files, logs, or persistent shell history.
Use `swift run opl-fleet-agent-headless --help` for the remaining current options.

## Accept an installation

Prefer a published verified release for user installation. A source build is
a development artifact and does not establish release trust. After installation,
read back the actual path/version, macOS signature/notarization/Gatekeeper state
or Windows file version, access to the intended session root, and metrics after
a real refresh. With Gateway enabled, also read back the approved device and
the server's accepted machine identity.

Zero throughput can be valid when no request completed in the window; inspect
collection status before diagnosing a zero as failure. Last-known values with
an error or stale status are not fresh observations. Tests and discovery of a
release cannot substitute for installed-runtime acceptance.
