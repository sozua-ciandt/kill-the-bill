#!/usr/bin/env bash
# Usage: ./scripts/release.sh v0.2.0
set -euo pipefail

VERSION="${1:?Usage: $0 vX.Y.Z}"
REPO="sozua-ciandt/kill-the-bill"

echo "==> Tagging ${VERSION}"
git tag -a "${VERSION}" -m "Release ${VERSION}"
git push origin "${VERSION}"

echo ""
echo "==> GitHub Actions will build and create the release."
echo "    Watch: https://github.com/${REPO}/actions"
echo ""
echo "==> Once the release is ready, update the cask:"
echo "    curl -sL https://github.com/${REPO}/releases/download/${VERSION}/KillTheBill.app.zip | shasum -a 256"
echo ""
echo "==> Then update ~/Projetos/homebrew-tap/Casks/kill-the-bill.rb"
echo "    with the new version and sha256, and push."
