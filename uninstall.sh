#!/bin/bash
set -euo pipefail

APP_NAME="KillTheBill"
DISPLAY_NAME="Kill the Bill"

remove_app() {
  target="$1"

  if [ ! -e "$target" ]; then
    return
  fi

  if [ -w "$(dirname "$target")" ]; then
    rm -rf "$target"
  else
    sudo rm -rf "$target"
  fi

  printf 'Removed %s\n' "$target"
}

pkill -x "$APP_NAME" 2>/dev/null || true

if [ -n "${KILL_THE_BILL_INSTALL_DIR:-}" ]; then
  remove_app "$KILL_THE_BILL_INSTALL_DIR/$APP_NAME.app"
else
  remove_app "/Applications/$APP_NAME.app"
  remove_app "$HOME/Applications/$APP_NAME.app"
fi

printf 'Uninstalled %s.\n' "$DISPLAY_NAME"
