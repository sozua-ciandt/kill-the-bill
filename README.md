# Kill the Bill

Track Claude Code and Codex token usage and cost from your macOS menu bar.

## Install

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sozua-ciandt/kill-the-bill/main/install.sh)"
```

The installer downloads the latest release source, builds the app locally, and
installs `KillTheBill.app` into `/Applications`. If administrator permission is
not available, it installs into `~/Applications` instead.

Requires macOS 14+ and Xcode Command Line Tools. If the command line tools are
missing, the installer will open Apple's installer and ask you to run the command
again after it finishes.

## Reinstall or update

Run the install command again. It replaces the existing app with the latest
release.

## Uninstall

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/sozua-ciandt/kill-the-bill/main/uninstall.sh)"
```

## Contributing

Development setup and custom transcript provider docs are in
[CONTRIBUTING.md](CONTRIBUTING.md).
