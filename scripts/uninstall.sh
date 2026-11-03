#!/bin/bash
# Removes Parseley from this Mac: the app, the `parseley` command, its settings, login
# item and Accessibility entry. Asks before deleting your clipboard history.
#
#   curl -fsSL https://raw.githubusercontent.com/rolandoo0/parseley/main/scripts/uninstall.sh | bash
#
# (Or from the app: Settings → General → Uninstall Parseley…)
#
# Options (environment variables):
#   PARSELEY_DELETE_HISTORY=1   also delete the history without asking
#   PARSELEY_KEEP_HISTORY=1     keep the history without asking
#   PARSELEY_APP_DIR / PARSELEY_BIN_DIR   also look in these folders (as for install.sh)
set -euo pipefail

BUNDLE_IDS=("io.github.rolandoo0.parseley" "com.example.parseley")   # current and pre-0.1.0
DATA_DIR="$HOME/Library/Application Support/Parseley"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

[ "$(uname -s)" = "Darwin" ] || { echo "This is for macOS." >&2; exit 1; }

# --- Quit ---------------------------------------------------------------------------------
if pgrep -x Parseley >/dev/null 2>&1; then
  say "Quitting Parseley"
  osascript -e 'quit app "Parseley"' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do pgrep -x Parseley >/dev/null 2>&1 || break; sleep 1; done
  pkill -x Parseley 2>/dev/null || true
fi

removed=()
remove() {   # remove <path>: deletes if present, notes it
  if [ -e "$1" ] || [ -L "$1" ]; then
    if rm -rf "$1" 2>/dev/null; then removed+=("$1"); else note "Couldn't remove $1 (try: sudo rm -rf \"$1\")"; fi
  fi
}

# --- App and CLI --------------------------------------------------------------------------
say "Removing the app and the parseley command"
remove "/Applications/Parseley.app"
remove "$HOME/Applications/Parseley.app"
remove "/usr/local/bin/parseley"
remove "$HOME/.local/bin/parseley"
[ -n "${PARSELEY_APP_DIR:-}" ] && remove "$PARSELEY_APP_DIR/Parseley.app"
[ -n "${PARSELEY_BIN_DIR:-}" ] && remove "$PARSELEY_BIN_DIR/parseley"

# --- Settings, permissions, caches --------------------------------------------------------
say "Removing settings and permissions"
for id in "${BUNDLE_IDS[@]}"; do
  defaults delete "$id" >/dev/null 2>&1 || true
  remove "$HOME/Library/Preferences/$id.plist"
  remove "$HOME/Library/Caches/$id"
  remove "$HOME/Library/HTTPStorages/$id"
  remove "$HOME/Library/Saved Application State/$id.savedState"
  tccutil reset Accessibility "$id" >/dev/null 2>&1 || true
done
# The login item (registered with SMAppService) goes away with the app itself.

# --- History ------------------------------------------------------------------------------
if [ -d "$DATA_DIR" ]; then
  answer="n"
  if [ -n "${PARSELEY_DELETE_HISTORY:-}" ]; then
    answer="y"
  elif [ -z "${PARSELEY_KEEP_HISTORY:-}" ] && [ -r /dev/tty ]; then
    # stdin is this script when run with `curl | bash`, so ask on the terminal itself.
    printf 'Also delete your clipboard history (%s)? [y/N] ' "$DATA_DIR" > /dev/tty
    read -r answer < /dev/tty || answer="n"
  fi
  case "$answer" in
    [yY]*) remove "$DATA_DIR" ;;
    *) note "Kept your clipboard history in $DATA_DIR" ;;
  esac
fi

say "Parseley is uninstalled."
if [ ${#removed[@]} -gt 0 ]; then
  for path in "${removed[@]}"; do note "removed $path"; done
fi
note "Reinstall any time: curl -fsSL https://raw.githubusercontent.com/rolandoo0/parseley/main/scripts/install.sh | bash"
