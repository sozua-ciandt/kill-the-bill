#!/bin/bash
set -euo pipefail

APP_NAME="KillTheBill"
DISPLAY_NAME="Kill the Bill"
REPO="sozua-ciandt/kill-the-bill"
DEFAULT_INSTALL_DIR="/Applications"

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}

trap cleanup EXIT

if [ "$(uname -s)" != "Darwin" ]; then
  fail "$DISPLAY_NAME can only be installed on macOS."
fi

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$macos_major" -lt 14 ]; then
  fail "$DISPLAY_NAME requires macOS 14 or newer."
fi

if ! xcrun --find swift >/dev/null 2>&1; then
  log "Xcode Command Line Tools are required to build $DISPLAY_NAME."
  log "Opening Apple's installer. Run this script again after it finishes."
  xcode-select --install >/dev/null 2>&1 || true
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  fail "curl is required."
fi

if ! command -v tar >/dev/null 2>&1; then
  fail "tar is required."
fi

latest_ref() {
  if [ -n "${KILL_THE_BILL_REF:-}" ]; then
    printf '%s\n' "$KILL_THE_BILL_REF"
    return
  fi

  ref="$(
    curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1 \
      || true
  )"

  if [ -n "$ref" ]; then
    printf '%s\n' "$ref"
  else
    printf '%s\n' "main"
  fi
}

copy_app() {
  src="$1"
  install_dir="$2"
  target="$install_dir/$APP_NAME.app"

  if [ ! -d "$install_dir" ]; then
    mkdir -p "$install_dir" 2>/dev/null || sudo mkdir -p "$install_dir"
  fi

  if [ -w "$install_dir" ]; then
    rm -rf "$target"
    ditto "$src" "$target"
  else
    sudo mkdir -p "$install_dir"
    sudo rm -rf "$target"
    sudo ditto "$src" "$target"
  fi
}

requested_install_dir="${KILL_THE_BILL_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
install_dir="$requested_install_dir"

if [ "$install_dir" = "$DEFAULT_INSTALL_DIR" ] && [ ! -w "$install_dir" ]; then
  log "Installing to $install_dir requires administrator permission."
  if ! sudo -v; then
    install_dir="$HOME/Applications"
    log "Administrator permission was not granted. Installing to $install_dir instead."
    mkdir -p "$install_dir"
  fi
fi

ref="$(latest_ref)"
archive_url="https://github.com/$REPO/archive/$ref.tar.gz"
WORK_DIR="$(mktemp -d)"
archive="$WORK_DIR/source.tar.gz"
source_dir="$WORK_DIR/source"

log "Downloading $DISPLAY_NAME $ref..."
curl -fL "$archive_url" -o "$archive"

mkdir -p "$source_dir"
tar -xzf "$archive" -C "$source_dir" --strip-components=1

cd "$source_dir"

log "Building $DISPLAY_NAME..."
swift build -c release --quiet

bundle="$source_dir/.build/install/$APP_NAME.app"
binary="$source_dir/.build/release/$APP_NAME"

if [ ! -x "$binary" ]; then
  fail "Build finished, but $binary was not found."
fi

mkdir -p "$bundle/Contents/MacOS"
mkdir -p "$bundle/Contents/Resources"
cp "$binary" "$bundle/Contents/MacOS/$APP_NAME"
cp "Info.plist" "$bundle/Contents/Info.plist"
cp "assets/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$bundle"

log "Installing to $install_dir/$APP_NAME.app..."
copy_app "$bundle" "$install_dir"

installed_app="$install_dir/$APP_NAME.app"
xattr -dr com.apple.quarantine "$installed_app" 2>/dev/null || true

log "Installed $DISPLAY_NAME."

if [ "${KILL_THE_BILL_OPEN:-1}" != "0" ]; then
  open "$installed_app"
fi
