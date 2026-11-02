# Parseley

A macOS menu-bar clipboard manager focused on numbers and data. Fully local: no
network, no accounts, no analytics.

**Status:** M3 (capture, storage, history panel, hotkey, paste, number parser, stats,
transforms). Settings come in M4.

## Requirements

- macOS 14+
- Xcode 16+ (needed for Swift 6 tools and Swift Testing)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build & run

```sh
xcodegen                 # generates Parseley.xcodeproj from project.yml
open Parseley.xcodeproj
```

In Xcode, pick the **Parseley** scheme and press ⌘R. There's no window and no Dock
icon. Look for the clipboard icon in the menu bar.

Run `xcodegen` again whenever you add or remove files under `App/` or edit `project.yml`.

## Using it

| Key | Action |
|---|---|
| ⌘⇧V (anywhere) | Open / close the history panel near the mouse |
| type | Live search |
| ↑ ↓ / Page Up, Page Down | Move selection |
| ↩ or double-click | Paste the clip into the app you were in |
| ⌘↩ | Copy only (don't paste) |
| ⌘P | Pin / unpin |
| ⌘⌫ | Delete |
| esc or click outside | Close |

Right-click a row for the same actions.

### Numbers & transforms

Select a clip that contains 2+ numbers and a **stats strip** appears under the preview:
Count · Sum · Average · Median · Min · Max. Click any tile to copy its value (plain
digits, e.g. `1492.5`, ready for a spreadsheet).

The parser understands `$1,204.50`, `(300)` (negative), `12%`, `-4.5`, `1.2k`, `3M`,
lists separated by newlines/tabs/commas/spaces, and columns pasted from Excel or Google
Sheets. It ignores dates, times, versions, IPs, phone numbers and things like `A1` or
`SKU-1234`. US formatting only for now (`1,204.50`, not `1.204,50`).

Stats are per clip: copy a whole column at once. (Adding up numbers copied one at a
time is the "running tally" mode planned for v2.)

**Transform buttons** (result is copied, added to history and selected, so ↩ pastes it):
Comma list · SQL IN · JSON array · Sort ↑ · Sort ↓ · Dedupe · Clean whitespace ·
Plain numbers (strips `$` and thousands separators).

Heads-up: while Parseley runs, ⌘⇧V no longer triggers "Paste and Match Style" in other
apps. A global hotkey wins. Rebinding comes with Settings in M4.

## Signing & the Accessibility permission (manual steps)

Auto-paste works by simulating ⌘V, and macOS only allows that for apps the user has
approved under **System Settings → Privacy & Security → Accessibility**. Without it,
Parseley still works: ↩ copies the clip and the panel shows a banner; you press ⌘V
yourself.

1. **Give the app a stable signature** (once). macOS ties the permission to the app's
   code signature. With the default ad-hoc signing, every rebuild looks like a new app
   and the permission silently stops working. In `project.yml` set
   `DEVELOPMENT_TEAM` to your Team ID and `CODE_SIGN_IDENTITY` to `"Apple Development"`
   (see the comments there), then run `xcodegen`. A free Apple ID works: add it under
   Xcode → Settings → Accounts; the Team ID is shown on developer.apple.com → Account →
   Membership, or in Xcode's Signing & Capabilities tab once you select the team.
2. Run the app, open the panel and press ↩ (or click **Enable Auto-Paste…**). macOS
   shows a prompt; click **Open System Settings** and switch **Parseley** on.
3. Close and reopen the panel. The orange banner should be gone.

**If auto-paste stops working after a rebuild** (Parseley shows as enabled but the
banner is back): the signature changed. In the Accessibility list select Parseley,
remove it with **–**, then grant it again. Equivalent from Terminal:
`tccutil reset Accessibility com.example.parseley` (use your bundle id).

No other permissions are needed. Reading the clipboard and registering a global
hotkey don't require any.

## Tests

All logic lives in the `ParseleyKit` Swift package, which has its own tests:

```sh
cd Packages/ParseleyKit
swift test
```

Or open `Packages/ParseleyKit/Package.swift` in Xcode and press ⌘U.

## Layout

```
App/                         Thin SwiftUI/AppKit shell: menu bar, floating panel, hotkey
Packages/ParseleyKit/
  Sources/ParseleyCore/      Pure Swift: Clip model, ClipStore protocol, TypeDetector,
                             PrivacyPolicy, NumberParser, NumberStats, Transforms
                             (shared `Transform` protocol + TransformChain for recipes)
  Sources/ParseleyStorage/   GRDBClipStore: SQLite via GRDB, migrations, retention
  Sources/ParseleyCapture/   ClipboardMonitor (polling pipeline) + NSPasteboard adapter
  Sources/ParseleyPaste/     Simulated ⌘V (CGEvent) + Accessibility permission helpers
```

Data lives at `~/Library/Application Support/Parseley/parseley.sqlite`. You can inspect
it with `sqlite3`: `sqlite3 ~/Library/Application\ Support/Parseley/parseley.sqlite 'select id, kind, sourceBundleID, substr(content,1,40) from clip order by lastUsedAt desc limit 20'`.

## Privacy

- Clips whose pasteboard item carries `org.nspasteboard.ConcealedType` or
  `org.nspasteboard.TransientType` are never read or stored. Password managers
  such as 1Password and Bitwarden set these markers. A few legacy markers are also
  honoured; see `PrivacyPolicy.swift`.
- An excluded-apps list is supported by the capture pipeline. The Settings UI for it
  comes in M4.
- Whatever is on the clipboard when Parseley launches is not imported.
