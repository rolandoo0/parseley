# Parseley

A macOS menu-bar clipboard manager focused on numbers and data. Fully local: no
network, no accounts, no analytics.

**Status:** v2: history panel, number parsing/stats, transforms, series (running
tally), modes, command bar, per-column table stats, recipes, paste queue, CLI + MCP
server, onboarding. CI builds and tests every push on macOS.

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
| ⌘-click / ⇧-click | Select several clips (combined stats) |
| ⌘1 – ⌘6 | Copy a stat (⌘1 = the mode's main stat) |
| `>` in search | Command bar: transforms, stats, series, modes by name |
| esc | Leave search / command bar, then close |
| ⌃⌥⌘T (anywhere) | Start / stop a series |
| ⌃⌥⌘N (anywhere) | New series |
| ⌃⌥⌘C (anywhere) | Copy the series total (or the last series' total) |
| ⌃⌥⌘V (anywhere) | Paste the next item of the paste queue |

Right-click a row for the same actions.

### Numbers & transforms

Select a clip that contains 2+ numbers and a **stats strip** appears under the preview:
Count · Sum · Average · Median · Min · Max. Click any tile to copy its value (plain
digits, e.g. `1492.5`, ready for a spreadsheet).

The parser understands `$1,204.50`, `(300)` (negative), `12%`, `-4.5`, `1.2k`, `3M`,
lists separated by newlines/tabs/commas/spaces, and columns pasted from Excel or Google
Sheets. It ignores dates, times, versions, IPs, phone numbers and things like `A1` or
`SKU-1234`. US (`1,204.50`) or European (`1.204,50`) formatting, set per mode.

**Multi-select:** ⌘-click rows to pick several clips, ⇧-click for a range. Stats then
combine every number across them, and transforms run over all of them (one per line).

### Series (running tally)

Start a series (⌃⌥⌘T, or the menu bar) and every number you copy, from any app, adds
up in a small glass bar that floats near the top of the screen. Drag it anywhere.

- **What counts:** copies that are *only* numbers (a value, a list, a spreadsheet column
  or range) are added automatically. Copies that mix text and numbers ("Invoice #4512,
  total $1,200") are listed as *skipped*: click **Add** to include one.
- **Hybrid counting:** each copy is one row in the bar (undo removes it in one go), but
  stats count every value: copying 50, then a column of 120/80/200 gives count 4, sum 450.
- **New task?** After an idle gap (default 10 min) or, optionally, when numbers start
  coming from another app, the bar *asks* whether to start a new series. It never
  splits on its own. "Start new series" moves that copy into a fresh series.
- Click **Σ** to copy the total; tiles copy any stat; **Copy values** copies the whole
  column. ⌃⌥⌘N ends the series and starts a new one. Past series are kept: menu bar →
  Recent Series copies a past total.
- From the history panel, **Add to series** adds the selected clip(s) (starting a
  series if none is running).

### Modes

A mode tailors Parseley to a task, and switches automatically with the app in front:

| Mode | Apps (editable) | What changes |
|---|---|---|
| General | everything else | defaults |
| Finance | Excel, Numbers, QuickBooks, Xero | Sum first; Plain numbers / Comma list / Sort ↓ first |
| SQL | DataGrip, TablePlus, Postico, Sequel Ace, DBeaver… | Count first; SQL IN / Dedupe / JSON first |
| Dev | VS Code, Xcode, Cursor, Zed, Terminal, iTerm | JSON / SQL first; copies don't count toward a series |
| Writing | Pages, Word, Notion, Obsidian, Bear, Notes | numbers hidden; copies don't count toward a series |

Each mode sets: its apps, number format (`1,204.50` or European `1.204,50`), whether
stats/sums show, whether copies count toward a running series, the main stat (⌘1), and
which transforms come first. The menu-bar icon and the chip in the panel header show the
active mode; click the chip (or menu bar → Mode) to lock a mode by hand, or go back to
Automatic. Edit, add and remove modes in Settings → Modes.

### Tables

Copy a range from Excel / Numbers / Google Sheets and the panel shows column chips
(All · Q1 · Q2…, with the header row detected). Pick one to get that column's stats;
⌘1–⌘6 and the command bar (`>sum of Q1`) follow it.

### Recipes

Saved chains of transforms, e.g. *Clean whitespace → Dedupe → Sort ↑ → SQL IN*. They
appear after the transform buttons and in the command bar. Edit them in Settings →
Recipes (with a live preview). A mode can **run a recipe on every copy** (Settings →
Modes): the result replaces the clipboard, and the original stays in history.

### Paste queue

⌘-click several clips → **Queue** (or `>paste queue`). Then in any app, each ⌃⌥⌘V
pastes the next one: handy for filling forms or a column of cells. When the queue
ends, your previous clipboard comes back. Status and Cancel are in the menu bar.

### Series totals in history

When a series ends (Stop, New series, or splitting at a prompt) its total is saved to
your history as a **Series total** clip: `Σ 4,210.50 · Q3 expenses · 12 values`.
Pasting it pastes the number. Series totals are never removed by the history limit or
"Clear All but Pinned".

### Command bar

Type `>` in the panel's search field: `>sql`, `>cs` (copy sum), `>new` (new series),
`>fin` (mode: Finance)… ↑/↓ and ⏎ run a command on the clip(s) that were selected.

### Settings (menu bar → Settings…)

- **General:** rebind the panel hotkey, history limit (100–10,000), launch at login,
  clear history.
- **Privacy:** excluded apps (copies made in them are never saved).
- **Modes:** edit or add task profiles (apps, number format, main stat, transforms).
- **Series:** hotkeys, idle-gap question (off/5–60 min), ask on app switch.

Launch at login registers the app where it currently lives; for a stable login item,
copy Parseley.app to /Applications first.

**Transform buttons** (result is copied, added to history and selected, so ↩ pastes it):
Comma list · SQL IN · JSON array · Sort ↑ · Sort ↓ · Dedupe · Clean whitespace ·
Plain numbers (strips `$` and thousands separators).

Heads-up: while Parseley runs, ⌘⇧V no longer triggers "Paste and Match Style" in other
apps. A global hotkey wins. Rebind it in Settings → General.

## Command line & AI assistants (MCP)

The `parseley` tool reads your history (read-only) from the terminal:

```sh
cd Packages/ParseleyKit
swift build -c release --product parseley
cp .build/release/parseley /usr/local/bin/      # or anywhere on your PATH
```
(CI also uploads a prebuilt `parseley` binary as an artifact on every push.)

```sh
parseley recent -n 10              # latest clips
parseley search invoice            # find clips
pbpaste | parseley stats           # stats of anything piped in
parseley sum 42                    # sum of clip #42
pbpaste | parseley transform sql.in
parseley series                    # running and past series
parseley sql "SELECT app, ROUND(SUM(value),2) FROM numbers GROUP BY app ORDER BY 2 DESC"
parseley sql --help                # the SQL views: clips, numbers, series_list, series_values
```

**MCP server**: lets Claude (or any MCP client) search your history, compute stats,
run transforms and read-only SQL. It runs only when the client starts it, on your Mac.

- Claude Code: `claude mcp add parseley -- /usr/local/bin/parseley mcp`
- Claude Desktop: add to `~/Library/Application Support/Claude/claude_desktop_config.json`:
  ```json
  { "mcpServers": { "parseley": { "command": "/usr/local/bin/parseley", "args": ["mcp"] } } }
  ```

Tools: `recent_clips`, `search_clips`, `get_clip`, `number_stats`, `transform_text`,
`list_series`, `query_sql`. Note this gives the assistant access to your clipboard
history (excluding anything Parseley never stored: password-manager copies and
excluded apps).

## Releases

Push a tag (`git tag v0.2.0 && git push origin v0.2.0`) and the Release workflow builds
`Parseley-0.2.0.dmg` and `parseley-cli-0.2.0.zip` into a draft GitHub Release. Without
signing secrets the app is unsigned (first open: right-click → Open). To ship signed
and notarized builds, add the secrets listed at the top of
`.github/workflows/release.yml` (needs a paid Apple Developer account).

## Performance notes

- Lists never load clip text: each clip stores a preview, line count, number count and
  sum when it's captured (listing 300 large clips: ~59 KB / 9 ms instead of ~30 MB / 1.6 s).
- Full text is loaded only for the selected clip(s), from a small bounded cache, and
  everything the panel holds is released when it closes.
- Numbers are parsed once per copy (in the source app's format) and stored per clip
  (`clipNumber` table), which also powers SQL.
- Copies over 200,000 characters are stored as plain text without number scanning.

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
App/                         SwiftUI/AppKit shell: menu bar, panel, series bar, settings,
                             onboarding, toast, paste queue, modes/recipes controllers
Packages/ParseleyKit/
  Sources/ParseleyCore/      Pure Swift: Clip model, ClipStore protocol, TypeDetector,
                             PrivacyPolicy, NumberParser, NumberStats, Transforms
                             (shared `Transform` protocol + TransformChain for recipes),
                             Series + SeriesTracker (running-tally engine),
                             Mode + ModeLibrary (task profiles), FuzzyMatch
  Sources/ParseleyStorage/   ParseleyDatabase (one SQLite file), GRDBClipStore,
                             GRDBSeriesStore, migrations
  Sources/ParseleyCapture/   ClipboardMonitor (polling pipeline) + NSPasteboard adapter
  Sources/ParseleyPaste/     Simulated ⌘V (CGEvent) + Accessibility permission helpers
  Sources/ParseleyTools/     CLI commands, read-only SQL, MCP server (testable)
  Sources/ParseleyCLI/       the `parseley` executable
```

Data lives at `~/Library/Application Support/Parseley/parseley.sqlite`. You can inspect
it with `sqlite3`: `sqlite3 ~/Library/Application\ Support/Parseley/parseley.sqlite 'select id, kind, sourceBundleID, substr(content,1,40) from clip order by lastUsedAt desc limit 20'`.

## Privacy

- Clips whose pasteboard item carries `org.nspasteboard.ConcealedType` or
  `org.nspasteboard.TransientType` are never read or stored. Password managers
  such as 1Password and Bitwarden set these markers. A few legacy markers are also
  honoured; see `PrivacyPolicy.swift`.
- Apps listed in Settings → Privacy are never captured.
- Whatever is on the clipboard when Parseley launches is not imported.
