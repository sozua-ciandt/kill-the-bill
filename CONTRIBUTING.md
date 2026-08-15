# Contributing

## Build from source

Requires macOS 14+ and Xcode Command Line Tools.

```bash
git clone https://github.com/sozua-ciandt/kill-the-bill
cd kill-the-bill
make install   # builds release binary, bundles .app, copies to /Applications
make run       # runs without installing
```

Before opening a pull request, run the same quality gate used by CI:

```bash
make check
```

For a faster test-only iteration, run `make test`.

## How it works

Claude Code writes JSONL transcripts to `~/.claude/projects/`, and Codex writes
session JSONL files to `~/.codex/sessions/`. Kill the Bill reads enabled native
harnesses, aggregates token usage by project and model, and estimates cost from
the [`models.dev`](https://models.dev/api.json) catalog.

Subscription fees are not tracked. Costs only estimate token-priced usage.

The monthly headline and local breakdowns intentionally have different sources
of truth. Flow is preferred for the authoritative month-to-date cost when it is
available. Claude and Codex transcripts remain responsible for today's cost,
turn counts, project/model breakdowns, and individual session estimates. See
[docs/architecture.md](docs/architecture.md) for the invariants and data flow.

## Pricing catalog

`models.dev` is the only source of token prices. The catalog is cached at
`~/.kill-the-bill/cache/models-dev-api.json` for 24 hours; when a refresh fails,
the last valid cached catalog remains available. If no catalog is available,
token usage is still counted and the affected turns are reported as unpriced.

The same model can be sold by multiple providers at different prices. When a
transcript includes a provider-qualified ID, such as
`google/gemini-2.5-pro`, Kill the Bill uses that exact provider. For the
unqualified model IDs normally emitted by Claude Code and Codex, the direct
model vendor is preferred deterministically (for example Anthropic for Claude
and OpenAI for GPT models).

Do not add hardcoded price overrides. Pricing corrections should be contributed
upstream to `models.dev` so every catalog consumer receives the same fix.

## Adding a harness

Harness support is implemented with a native parser under
`Sources/KillTheBill/DataSources/`. A new harness should include:

- A stable case in `Harness` and discovery that honors the user's enabled set.
- A parser that handles malformed or partial records without discarding an
  otherwise valid session.
- Fixtures covering token fields, model IDs, timestamps, deduplication, and
  sessions with unavailable pricing.
- Settings and documentation updates describing where its local logs are read.

Generic JSON CustomProvider rules and local pricing overrides are intentionally
not supported. Keeping parsers native makes session-level details and future
schema migrations explicit and testable.
