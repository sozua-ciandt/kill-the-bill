# Contributing

## Build from source

Requires macOS 14+ and Xcode Command Line Tools.

```bash
git clone https://github.com/sozua-ciandt/kill-the-bill
cd kill-the-bill
make install   # builds release binary, bundles .app, copies to /Applications
make run       # runs without installing
```

## How it works

Claude Code writes JSONL transcripts to `~/.claude/projects/`, and Codex writes
session JSONL files to `~/.codex/sessions/`. Kill the Bill reads both,
aggregates token usage by project and model, and estimates cost from
`models.dev` pricing when available, with local custom overrides.

Subscription fees are not tracked. Costs only estimate token-priced usage.

## Custom transcript providers

Add JSON provider rules to `~/.kill-the-bill/providers/*.json` to support other
tools or custom proxies that write JSONL usage logs. A rule defines where
transcript files live, which JSON records count as usage events, how to read
token/model/project fields, and optional pricing.

Example Gemini-style rule:

```json
{
  "id": "gemini",
  "name": "Gemini",
  "files": {
    "roots": ["~/.gemini/telemetry"],
    "recursive": true,
    "extensions": ["jsonl"]
  },
  "event": {
    "matches": [
      { "path": ["event_name"], "equals": "gemini_api_response" }
    ],
    "workspacePath": ["workspace"],
    "workspaceDefault": "Gemini",
    "modelPath": ["model"],
    "modelDefault": "gemini",
    "inputTokensPath": ["usage_metadata", "prompt_token_count"],
    "outputTokensPath": ["usage_metadata", "candidates_token_count"],
    "cacheReadTokensPath": ["usage_metadata", "cached_content_token_count"],
    "totalTokensPath": ["usage_metadata", "total_token_count"]
  },
  "pricing": [
    {
      "model": "gemini-2.5-pro",
      "aliases": ["models/gemini-2.5-pro"],
      "input": 1.25,
      "output": 10.0,
      "cacheRead": 0.31
    }
  ]
}
```

Prices are USD per million tokens. If pricing is omitted, Kill the Bill tries to
resolve public provider/model pricing from the cached `models.dev` catalog.
Local rules always win, so keep explicit pricing here for proxies, private
models, discounts, or enterprise rates.

If your logs use different field names, change the `path` arrays to match the
JSON shape. If you want to keep rules elsewhere, set
`KILL_THE_BILL_PROVIDER_DIR` to that folder before launching the app.

For example, this JSONL record would match the rule above:

```json
{"event_name":"gemini_api_response","workspace":"my-app","model":"gemini-2.5-pro","usage_metadata":{"prompt_token_count":1200,"candidates_token_count":300,"cached_content_token_count":200,"total_token_count":1700}}
```

Custom providers are intentionally declarative. If a provider needs a non-JSONL
format or more complex parsing, add a new parser under
`Sources/KillTheBill/DataSources/`.

For tools that log provider-qualified model IDs such as
`google/gemini-2.5-pro`, public pricing can often be resolved automatically. The
catalog is cached at `~/.kill-the-bill/cache/models-dev-api.json` for 24 hours
and failure falls back to token tracking without cost.

For Codex proxies, a smaller pricing-only rule is enough because Codex already
has a built-in transcript parser:

```json
{
  "id": "my-codex-proxy",
  "name": "My Codex Proxy",
  "pricing": [
    {
      "model": "gpt-5.5",
      "aliases": ["gpt-5-5"],
      "input": 5.0,
      "output": 30.0,
      "cacheRead": 0.5,
      "cacheWrite": 0.0
    }
  ]
}
```
