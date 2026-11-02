# Parseley

A macOS menu-bar clipboard manager focused on numbers and data. Fully local: no
network, no accounts, no analytics.

**Status:** M1 (capture + storage). The panel, hotkey and paste come in M2; the number
parser, stats and transforms in M3; settings in M4.

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

**Signing (M1):** the project uses "Sign to Run Locally", so no Apple account is
needed yet. If Xcode still complains, open the target's *Signing & Capabilities* tab
and pick your personal team.

## Tests

All logic lives in the `ParseleyKit` Swift package, which has its own tests:

```sh
cd Packages/ParseleyKit
swift test
```

Or open `Packages/ParseleyKit/Package.swift` in Xcode and press ⌘U.

## Layout

```
App/                         Thin SwiftUI/AppKit shell (menu bar, later panel + settings)
Packages/ParseleyKit/
  Sources/ParseleyCore/      Pure Swift: Clip model, ClipStore protocol, TypeDetector,
                             PrivacyPolicy (later: NumberParser, Stats, Transforms)
  Sources/ParseleyStorage/   GRDBClipStore: SQLite via GRDB, migrations, retention
  Sources/ParseleyCapture/   ClipboardMonitor (polling pipeline) + NSPasteboard adapter
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
