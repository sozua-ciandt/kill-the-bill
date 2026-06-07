# Kill the Bill

macOS menu bar app that shows your Claude Code usage and cost in real time.

Reads native session transcripts from `~/.claude/projects/` — no configuration needed, works with any Claude Code setup including custom proxies.

## Features

- Daily cost in the menu bar (color-coded: green < $5, orange < $20, red > $20)
- Token breakdown: input, output, cache read, cache write
- Per-model cost breakdown (Opus, Sonnet, Haiku)
- Per-project breakdown
- Launch at login toggle
- Refreshes every 30 seconds

## Install

```bash
brew tap sozua-ciandt/tap
brew install --cask --no-quarantine kill-the-bill
```

## Build from source

Requires macOS 14+ and Xcode Command Line Tools.

```bash
git clone https://github.com/sozua-ciandt/kill-the-bill
cd kill-the-bill
make install   # builds release binary, bundles .app, copies to /Applications
make run       # runs without installing
```

## Uninstall

```bash
brew uninstall --cask kill-the-bill
# or from source:
make uninstall
```

## How it works

Claude Code writes a JSONL transcript per session to `~/.claude/projects/<project>/<session>.jsonl`. Each assistant response includes a `usage` block with token counts. Kill the Bill reads those files, deduplicates streaming chunks, and computes cost using Anthropic's published pricing.

Works without an Anthropic API key — purely local, no network requests.
