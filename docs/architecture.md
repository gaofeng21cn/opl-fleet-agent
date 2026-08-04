# Architecture

## Goal

Display local Codex token throughput in the macOS menu bar with minute-level
freshness, low steady-state overhead, and no prompt-content processing outside
the local process.

## Data flow

```text
~/.codex/sessions/YYYY/MM/DD/*.jsonl
        -> incremental line reader
        -> stateful token_count parser
        -> replay/duplicate filter
        -> rolling event window
        -> MenuBarExtra, snapshot CLI, and optional OPL Fleet Gateway push agent
```

The scanner discovers files in today's and yesterday's session directories,
parses recently modified files once to establish state, then reads only appended
bytes. The UI refresh cadence is selectable while rolling windows remain fixed
at 1 minute, 5 minutes, 30 minutes, and 1 hour. The selected window is shared
by the panel and menu bar and persisted in `UserDefaults`, so changing the
segmented control updates the compact menu bar value immediately.

## Update flow

```text
github.com/.../releases/latest (HEAD redirect)
        -> validate release tag and required asset URLs
        -> user confirms Update now
        -> download DMG and published SHA-256
        -> verify checksum, expected version, Developer ID team, and Gatekeeper
        -> stage, back up, atomically replace, and relaunch
```

The updater checks once after launch and every six hours while the app remains
running. It is independent of the session scanner: requests contain no Codex
log data, and only GitHub release metadata and assets are accessed. Automatic
checking never silently installs or terminates the app.

## Optional OPL Fleet Gateway push flow

```text
rolling aggregate snapshot
        -> explicit field allowlist
        -> mDNS discovery
        -> one-time visible pairing approval
        -> per-device P-256 signed POST
        -> user-configured OPL Fleet Telemetry Gateway
```

The menu bar app discovers compatible servers and uses a private P-256 device
key stored in the macOS Keychain. The server receives only the public key after
the user confirms a six-digit code on the local approval page. Each push signs
the method, path, timestamp, nonce, and body hash. Existing bearer tokens remain
a compatibility path, and the headless source agent still requires one.

The payload contains only aggregate token totals/rates, request counts,
active-session count, machine labels, collection status, and timestamps.
Session identifiers, paths, prompts, responses, and tool content never cross
the process boundary. Collection failures retain the last successful aggregate
values and mark the snapshot as an error; transport failures retry without
affecting local collection.

## OPL Fleet Agent boundary

The product is presented to users only as `OPL Fleet Agent`. Windows now uses the
`OPLFleetAgent.exe` executable and branded release assets. A legacy upgrade may create a
one-time `CodexTPS.exe` bridge in the old installation directory; the settings location,
`_codex-tps._tcp` discovery service, and
legacy release asset names remain compatibility identities for the upgrade chain.
The `oplFleet` extension is a versioned, aggregate-only envelope. It describes
the local Agent's observation, doctor, execution-constraint, and sanitized-receipt
capabilities across Local, Direct, and Fleet modes. The Agent can constrain and
report its own host execution, but it never owns registry, policy, admission,
lease, or dispatch authority. OPL Flow, the private Instance, and the Fleet
Controller remain authoritative. OPL Fleet Gateway is presented as `OPL Fleet Cockpit`
and its Gateway only stores, aggregates, and projects telemetry; it does not
schedule or dispatch work.

## Release trust flow

```text
universal app
        -> Developer ID + Hardened Runtime + trusted timestamp
        -> signed DMG
        -> Apple notarization
        -> stapled ticket
        -> Gatekeeper, signature, architecture, and checksum verification
        -> GitHub Release assets pinned by SHA-256
```

The release workflow fails closed when protected Apple credentials are missing.
Local development builds may remain ad-hoc signed, but public release assets
must carry Team ID `SVVC4TA784` and pass the final notarized-byte verifier.

## Accounting invariants

1. `last_token_usage` is the request increment.
2. `total_token_usage` is cumulative state, never a direct increment when a
   `last_token_usage` value exists.
3. `total_tokens` is the throughput numerator. `cached_input_tokens` is a subset
   of input and `reasoning_output_tokens` is a subset of output.
4. Forked children can rewrite replay timestamps. The parser reads fork metadata
   and ignores inherited history until a verifiable child UUIDv7 turn begins;
   legacy UUIDv4 turns inside replay do not establish that boundary.
5. A stable event identity provides a second cross-file duplicate guard after
   fork replay filtering.
6. Collection decodes only `session_meta`, `task_started`, `turn_context`, and
   `token_count` records; message and tool-content lines remain opaque bytes.
7. No message body crosses the parser boundary.

## Product boundaries

- Tokscale remains the historical analysis/export surface; it is not invoked on
  the menu bar refresh path.
- Local usage events are operational telemetry, not billing authority. The app
  does not attribute usage to an API key or reconcile provider-side charges.
- Codex JSONL is an implementation surface. Fixture tests cover the shapes used
  here so schema drift fails visibly.
- Network access is restricted to GitHub release checks/update downloads and
  the explicitly configured OPL Fleet Gateway push endpoint. There is no analytics,
  login, or conversation-content upload path.
