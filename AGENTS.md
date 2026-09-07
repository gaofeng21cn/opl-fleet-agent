# OPL Fleet Agent Repository Guide

This repository owns local-first macOS menu bar and Windows tray monitors for
Codex token throughput. They read Codex session JSONL files and never upload
conversation content.

## Runtime Contract

- Follow [architecture](docs/architecture.md) for accounting, replay, transport,
  and native/Package ownership. Verify changes against the source and current
  callers; prose is not a second runtime contract.
- Preserve the parser's fork state machine and cross-file deduplication tests.
- Do not persist, log, transmit, or render prompt or response bodies.
- Network access includes GitHub release metadata/assets, the macOS aggregate
  Direct LAN server, and configured aggregate Gateway discovery/pairing/push.
  Conversation records never cross the network boundary.

## Development

Use [development](docs/development.md) for commands and qualification boundaries,
and [operations](docs/operations.md) for installed-runtime acceptance. Do not
infer installed or published state from source tests or old release receipts.

## Documentation Lifecycle

- Root READMEs are English/Chinese user-entry equivalents; keep their meaning
  aligned in the same change. They summarize capabilities and link to owners.
- `docs/architecture.md` owns implementation boundaries and invariants;
  `docs/operations.md` owns operator procedures; `docs/development.md` owns
  builds and release qualification. `windows/README.md` owns Windows installation
  and desktop operation. The Package Skill owns broker invocation only.
- Put each new subject in its existing owner. Split a document only when a new
  audience or independent task needs a separate entry. Link instead of copying
  detailed procedures, capability inventories, or acceptance records.
- When code, descriptors, callers, packaging, or workflows change, update the
  owning document and inbound references in the same change. Remove retired
  instructions instead of preserving aliases or completed checklists.
- Keep proposals separate from current behavior and state their unresolved
  decision. Once resolved, integrate durable rationale into its owner and delete
  the plan. Git and release/workflow records retain completed execution history;
  archive prose only when unique decision provenance still has future value.
- Legal notices retain their legal provenance purpose. Do not edit third-party
  license text as documentation cleanup.
- Verify local links/assets and `git diff --check`. Judge currentness from
  source and contracts; do not add prose-keyword, heading, or length assertions.

<!-- CODEGRAPH_START -->
## CodeGraph

- This repository uses the local `.codegraph/` index; it must remain Git ignored.
- Prefer CodeGraph for symbol, caller, impact, and flow queries. Use `rg` for
  literal text searches.
- Run `codegraph init .` or `codegraph sync .` when the index is missing or stale.
<!-- CODEGRAPH_END -->
