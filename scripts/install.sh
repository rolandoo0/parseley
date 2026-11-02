#!/bin/bash
# Installs Parseley (the menu-bar app) and the `parseley` command-line tool from the
# latest GitHub release. No Xcode needed.
#
#   curl -fsSL https://raw.githubusercontent.com/rolandoo0/parseley/main/scripts/install.sh | bash
#
# What it does: downloads the release DMG, checks its SHA-256, copies Parseley.app to
# /Applications (or ~/Applications), puts `parseley` in /usr/local/bin (or ~/.local/bin),
# and opens the app. Files fetched with curl aren't flagged as "downloaded from the
# internet", so macOS doesn't show its unidentified-developer prompt; the script also
# clears that flag in case it's there.
#
# Options (environment variables):
#   PARSELEY_VERSION=0.2.0     a specific version instead of the latest
#   PARSELEY_APP_DIR=…         where to put the app        (default /Applications)
#   PARSELEY_BIN_DIR=…         where to put the CLI        (default /usr/local/bin or ~/.local/bin)
#   PARSELEY_NO_CLI=1          skip the command-line tool
#   PARSELEY_NO_OPEN=1         don't open the app afterwards
#   PARSELEY_DMG / PARSELEY_CLI_ZIP   install from local files (used by CI)
#
# Uninstall: quit Parseley, then
#   rm -rf /Applications/Parseley.app "$(command -v parseley)"
#   rm -rf ~/Library/Application\ Support/Parseley    # your clipboard history
set -euo pipefail

REPO="rolandoo0/parseley"
APP_NAME="Parseley.app"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Parseley is a macOS app."
macos="$(sw_vers -productVersion)"
[ "${macos%%.*}" -ge 14 ] || die "Parseley needs macOS 14 Sonoma or later (this Mac has $macos)."

tmp="$(mktemp -d)"
mnt="$tmp/mnt"
cleanup() {
  [ -d "$mnt" ] && hdiutil detach -quiet "$mnt" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

dmg="${PARSELEY_DMG:-}"
cli_zip="${PARSELEY_CLI_ZIP:-}"

# --- Download ---------------------------------------------------------------------------
if [ -z "$dmg" ]; then
  if [ -n "${PARSELEY_VERSION:-}" ]; then
    api="https://api.github.com/repos/$REPO/releases/tags/v${PARSELEY_VERSION#v}"
  else
    api="https://api.github.com/repos/$REPO/releases/latest"
  fi
  say "Finding the release"
  json="$(curl -fsSL -H "Accept: application/vnd.github+json" "$api")" \
    || die "Couldn't read $api. Is there a published release yet?"
  # The asset URLs are the only "browser_download_url" fields in the response.
  urls="$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*"' | sed 's/.*"\(https:[^"]*\)"$/\1/' || true)"
  dmg_url="$(printf '%s\n' "$urls" | grep '\.dmg$' | head -1 || true)"
  cli_url="$(printf '%s\n' "$urls" | grep 'parseley-cli-.*\.zip$' | head -1 || true)"
  sums_url="$(printf '%s\n' "$urls" | grep 'SHA256SUMS\.txt$' | head -1 || true)"
  [ -n "$dmg_url" ] || die "The release has no DMG attached."

  say "Downloading $(basename "$dmg_url")"
  dmg="$tmp/$(basename "$dmg_url")"
  curl -fL --progress-bar -o "$dmg" "$dmg_url"
  if [ -n "$cli_url" ] && [ -z "${PARSELEY_NO_CLI:-}" ]; then
    cli_zip="$tmp/$(basename "$cli_url")"
    curl -fsSL -o "$cli_zip" "$cli_url"
  fi

  if [ -n "$sums_url" ]; then
    curl -fsSL -o "$tmp/SHA256SUMS.txt" "$sums_url"
    for f in "$dmg" ${cli_zip:+"$cli_zip"}; do
      expected="$(grep " $(basename "$f")\$" "$tmp/SHA256SUMS.txt" | awk '{print $1}')"
      actual="$(shasum -a 256 "$f" | awk '{print $1}')"
      [ -n "$expected" ] && [ "$expected" = "$actual" ] || die "Checksum mismatch for $(basename "$f"). Not installing."
    done
    note "Checksums verified."
  else
    note "No SHA256SUMS.txt in this release; skipping the checksum check."
  fi
fi

# --- Install the app ----------------------------------------------------------------------
app_dir="${PARSELEY_APP_DIR:-/Applications}"
mkdir -p "$app_dir" 2>/dev/null || true
if [ ! -w "$app_dir" ]; then
  app_dir="$HOME/Applications"
  mkdir -p "$app_dir"
  note "/Applications isn't writable for this user; installing to ~/Applications."
fi

say "Installing $APP_NAME to $app_dir"
mkdir -p "$mnt"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$dmg" || die "Couldn't open the DMG."
[ -d "$mnt/$APP_NAME" ] || die "The DMG doesn't contain $APP_NAME."

if pgrep -x Parseley >/dev/null 2>&1; then
  note "Quitting the running Parseley first."
  osascript -e 'quit app "Parseley"' >/dev/null 2>&1 || pkill -x Parseley || true
  sleep 1
fi
rm -rf "${app_dir:?}/$APP_NAME"
ditto "$mnt/$APP_NAME" "$app_dir/$APP_NAME"
hdiutil detach -quiet "$mnt" || true
xattr -dr com.apple.quarantine "$app_dir/$APP_NAME" 2>/dev/null || true

# --- Install the CLI ----------------------------------------------------------------------
if [ -n "$cli_zip" ] && [ -z "${PARSELEY_NO_CLI:-}" ]; then
  bin_dir="${PARSELEY_BIN_DIR:-}"
  if [ -z "$bin_dir" ]; then
    if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then bin_dir=/usr/local/bin; else bin_dir="$HOME/.local/bin"; fi
  fi
  mkdir -p "$bin_dir"
  ditto -x -k "$cli_zip" "$tmp/cli"
  install -m 0755 "$tmp/cli/parseley" "$bin_dir/parseley"
  xattr -d com.apple.quarantine "$bin_dir/parseley" 2>/dev/null || true
  say "Installed the parseley command to $bin_dir"
  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) note "Add it to your PATH:  echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.zshrc" ;;
  esac
fi

# --- Done ---------------------------------------------------------------------------------
version="$(defaults read "$app_dir/$APP_NAME/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
say "Parseley $version is installed."
note "It lives in the menu bar (no Dock icon). Press ⌘⇧V to open your clipboard history."
note "For auto-paste, allow Parseley in System Settings → Privacy & Security → Accessibility."
note "After an update, turn that switch off and on again if auto-paste stops working."
if [ -z "${PARSELEY_NO_OPEN:-}" ]; then
  open "$app_dir/$APP_NAME"
fi
