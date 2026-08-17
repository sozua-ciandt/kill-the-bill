#!/bin/bash
set -euo pipefail

APP_NAME="KillTheBill"
DISPLAY_NAME="Kill the Bill"
EXPECTED_BUNDLE_ID="dev.sozua-ciandt.kill-the-bill"
REPO="sozua-ciandt/kill-the-bill"
DEFAULT_INSTALL_DIR="/Applications"
USER_INSTALL_DIR="$HOME/Applications"
ASSET_URL="${KILL_THE_BILL_ASSET_URL:-https://github.com/$REPO/releases/latest/download/$APP_NAME.app.zip}"

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

for command in curl ditto codesign; do
  if ! command -v "$command" >/dev/null 2>&1; then
    fail "$command is required."
  fi
done

bundle_value() {
  app="$1"
  key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist" 2>/dev/null || true
}

bundle_id() {
  bundle_value "$1" "CFBundleIdentifier"
}

validate_app() {
  app="$1"

  if [ ! -d "$app" ] || [ -L "$app" ]; then
    printf 'Invalid application bundle: %s\n' "$app" >&2
    return 1
  fi

  identifier="$(bundle_id "$app")"
  if [ "$identifier" != "$EXPECTED_BUNDLE_ID" ]; then
    printf 'Unexpected bundle identifier in %s: %s\n' "$app" "${identifier:-missing}" >&2
    return 1
  fi

  executable_name="$(bundle_value "$app" "CFBundleExecutable")"
  case "$executable_name" in
    ""|*/*)
      printf 'Invalid CFBundleExecutable in %s\n' "$app" >&2
      return 1
      ;;
  esac
  if [ ! -x "$app/Contents/MacOS/$executable_name" ]; then
    printf 'Missing executable in %s\n' "$app" >&2
    return 1
  fi

  if [ ! -d "$app/Contents/Resources/KillTheBill_KillTheBill.bundle" ]; then
    printf 'Missing SwiftPM resource bundle in %s\n' "$app" >&2
    return 1
  fi

  if ! codesign --verify --deep --strict --verbose=2 "$app" >/dev/null 2>&1; then
    printf 'Code signature verification failed for %s\n' "$app" >&2
    return 1
  fi
}

ensure_directory() {
  directory="$1"
  if [ -d "$directory" ]; then
    return
  fi
  if ! mkdir -p "$directory" 2>/dev/null; then
    sudo mkdir -p "$directory"
  fi
}

run_in_directory() {
  directory="$1"
  shift
  if [ -w "$directory" ]; then
    "$@"
  else
    sudo "$@"
  fi
}

safe_remove_known_app() {
  target="$1"
  parent="$(dirname "$target")"

  if [ ! -e "$target" ]; then
    return
  fi
  identifier="$(bundle_id "$target")"
  if [ "$identifier" != "$EXPECTED_BUNDLE_ID" ]; then
    fail "Refusing to remove $target because its bundle identifier is ${identifier:-missing}."
  fi
  if ! codesign --verify --deep --strict "$target" >/dev/null 2>&1; then
    fail "Refusing to remove $target because its existing code signature is invalid."
  fi
  run_in_directory "$parent" rm -rf "$target"
  log "Removed old copy at $target (not recoverable)."
}

preflight_known_app_removal() {
  target="$1"

  if [ ! -e "$target" ]; then
    return
  fi
  identifier="$(bundle_id "$target")"
  if [ "$identifier" != "$EXPECTED_BUNDLE_ID" ]; then
    fail "Refusing to install while $target exists with bundle identifier ${identifier:-missing}."
  fi
  if ! codesign --verify --deep --strict "$target" >/dev/null 2>&1; then
    fail "Refusing to install while $target has an invalid code signature."
  fi
}

install_transactionally() {
  source_app="$1"
  install_dir="$2"
  target="$install_dir/$APP_NAME.app"
  transaction_id="$$"
  staged="$install_dir/.$APP_NAME.update-new-$transaction_id.app"
  backup="$install_dir/.$APP_NAME.update-backup-$transaction_id.app"
  had_target=0

  if [ -e "$staged" ] || [ -e "$backup" ]; then
    fail "Temporary update paths already exist in $install_dir."
  fi
  if [ -e "$target" ]; then
    identifier="$(bundle_id "$target")"
    if [ "$identifier" != "$EXPECTED_BUNDLE_ID" ]; then
      fail "Refusing to replace $target because its bundle identifier is ${identifier:-missing}."
    fi
    if ! codesign --verify --deep --strict "$target" >/dev/null 2>&1; then
      fail "Refusing to replace $target because its existing code signature is invalid."
    fi
  fi

  run_in_directory "$install_dir" ditto "$source_app" "$staged"
  if ! validate_app "$staged"; then
    run_in_directory "$install_dir" rm -rf "$staged"
    fail "The staged application failed validation."
  fi

  if [ -e "$target" ]; then
    run_in_directory "$install_dir" mv "$target" "$backup"
    had_target=1
  fi

  if ! run_in_directory "$install_dir" mv "$staged" "$target"; then
    if [ "$had_target" = "1" ]; then
      run_in_directory "$install_dir" mv "$backup" "$target" || true
    fi
    fail "Could not move the new application into place."
  fi

  if ! validate_app "$target"; then
    run_in_directory "$install_dir" rm -rf "$target" || true
    if [ "$had_target" = "1" ]; then
      run_in_directory "$install_dir" mv "$backup" "$target" || true
    fi
    fail "Installed application validation failed; the previous version was restored."
  fi

  if [ "$had_target" = "1" ]; then
    run_in_directory "$install_dir" rm -rf "$backup"
  fi
}

requested_install_dir="${KILL_THE_BILL_INSTALL_DIR:-}"
system_app="$DEFAULT_INSTALL_DIR/$APP_NAME.app"
user_app="$USER_INSTALL_DIR/$APP_NAME.app"

if [ -n "$requested_install_dir" ]; then
  install_dir="$requested_install_dir"
elif [ -e "$system_app" ]; then
  # Preserve the canonical path already registered with Service Management.
  install_dir="$DEFAULT_INSTALL_DIR"
elif [ -e "$user_app" ]; then
  install_dir="$USER_INSTALL_DIR"
else
  install_dir="$DEFAULT_INSTALL_DIR"
fi

if [ "$install_dir" = "$DEFAULT_INSTALL_DIR" ] && [ ! -w "$DEFAULT_INSTALL_DIR" ]; then
  log "Installing to $DEFAULT_INSTALL_DIR requires administrator permission."
  if ! sudo -v; then
    if [ -e "$system_app" ]; then
      fail "Administrator permission is required to replace the existing app in $DEFAULT_INSTALL_DIR."
    fi
    install_dir="$USER_INSTALL_DIR"
    log "Administrator permission was not granted. Installing to $install_dir instead."
  fi
fi

ensure_directory "$install_dir"

if [ "$install_dir" = "$USER_INSTALL_DIR" ] \
  && [ -e "$system_app" ] \
  && [ ! -w "$DEFAULT_INSTALL_DIR" ]; then
  log "Removing the verified old copy in $DEFAULT_INSTALL_DIR requires administrator permission."
  sudo -v || fail "Administrator permission is required before installing, so two startup copies are not left behind."
fi

# Validate the exact standard-location duplicate before replacing anything. The
# check is deliberately repeated during removal to protect against a race, but
# this preflight guarantees a successful transaction cannot discover an
# unremovable/unrelated second copy only after the new app is installed.
duplicate_app=""
if [ "$install_dir/$APP_NAME.app" = "$system_app" ]; then
  duplicate_app="$user_app"
elif [ "$install_dir/$APP_NAME.app" = "$user_app" ]; then
  duplicate_app="$system_app"
fi
if [ -n "$duplicate_app" ]; then
  preflight_known_app_removal "$duplicate_app"
fi

WORK_DIR="$(mktemp -d)"
archive="$WORK_DIR/$APP_NAME.app.zip"
expanded="$WORK_DIR/Expanded"
mkdir -p "$expanded"

log "Downloading the latest $DISPLAY_NAME release..."
curl -fL --retry 2 --connect-timeout 15 "$ASSET_URL" -o "$archive"

log "Extracting and validating the application..."
ditto -x -k "$archive" "$expanded"
candidate="$expanded/$APP_NAME.app"

top_level_count="$(find "$expanded" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
if [ "$top_level_count" != "1" ] || [ ! -d "$candidate" ]; then
  fail "The release archive must contain only $APP_NAME.app."
fi
validate_app "$candidate" || fail "The downloaded application failed security validation."

pkill -x "$APP_NAME" 2>/dev/null || true

log "Installing to $install_dir/$APP_NAME.app..."
install_transactionally "$candidate" "$install_dir"

installed_app="$install_dir/$APP_NAME.app"
if [ "$installed_app" = "$system_app" ]; then
  safe_remove_known_app "$user_app"
elif [ "$installed_app" = "$user_app" ]; then
  safe_remove_known_app "$system_app"
else
  log "Custom install directory selected; standard application locations were left untouched."
fi

version="$(bundle_value "$installed_app" "CFBundleShortVersionString")"
log "Installed $DISPLAY_NAME ${version:-unknown version}."

if [ "${KILL_THE_BILL_OPEN:-1}" != "0" ]; then
  open "$installed_app"
fi
