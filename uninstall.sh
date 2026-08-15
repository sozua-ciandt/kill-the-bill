#!/bin/bash
set -euo pipefail

APP_NAME="KillTheBill"
DISPLAY_NAME="Kill the Bill"
EXPECTED_BUNDLE_ID="dev.sozua-ciandt.kill-the-bill"

bundle_id() {
  /usr/libexec/PlistBuddy \
    -c 'Print :CFBundleIdentifier' \
    "$1/Contents/Info.plist" 2>/dev/null || true
}

remove_app() {
  target="$1"

  if [ ! -e "$target" ]; then
    return
  fi
  identifier="$(bundle_id "$target")"
  if [ "$identifier" != "$EXPECTED_BUNDLE_ID" ]; then
    printf 'Error: refusing to remove %s because its bundle identifier is %s.\n' \
      "$target" "${identifier:-missing}" >&2
    exit 1
  fi
  if ! codesign --verify --deep --strict "$target" >/dev/null 2>&1; then
    printf 'Error: refusing to remove %s because its code signature is invalid.\n' "$target" >&2
    exit 1
  fi

  if [ -w "$(dirname "$target")" ]; then
    rm -rf "$target"
  else
    sudo rm -rf "$target"
  fi

  printf 'Removed %s (not recoverable).\n' "$target"
}

pkill -x "$APP_NAME" 2>/dev/null || true

if [ -n "${KILL_THE_BILL_INSTALL_DIR:-}" ]; then
  remove_app "$KILL_THE_BILL_INSTALL_DIR/$APP_NAME.app"
else
  remove_app "/Applications/$APP_NAME.app"
  remove_app "$HOME/Applications/$APP_NAME.app"
fi

printf 'Uninstalled %s. Disable “Launch at Login” before uninstalling to remove its System Settings registration.\n' "$DISPLAY_NAME"
