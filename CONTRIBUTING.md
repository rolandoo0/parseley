# Contributing to Parseley

Thanks for helping. Parseley is a small macOS app; keeping it fast, private and simple
matters more than adding options.

## Ground rules

- **Local only.** No network calls, accounts, telemetry or crash reporting. Pull
  requests that add any will be declined.
- **Logic goes in the package.** Parsing, stats, transforms, series and storage live in
  `Packages/ParseleyKit` and are covered by tests (they also run on Linux). The app
  target (`App/`) is UI and macOS glue.
- **Tests first for logic.** New parsing rules, transforms or stats come with Swift
  Testing tests in `Packages/ParseleyKit/Tests`.

## Getting started

```sh
brew install xcodegen
xcodegen && open Parseley.xcodeproj      # app: ⌘R
cd Packages/ParseleyKit && swift test     # logic tests
```

Builds are ad-hoc signed by default. To keep macOS's Accessibility permission between
rebuilds, put your Team ID in `Config/Local.xcconfig` (see `Config/Signing.xcconfig`).

## Pull requests

- One change per pull request, with a short description of what and why.
- CI (macOS) must pass: package tests, the CLI and the app build.
- If a change affects what the welcome tour shows, update `scripts/tour-video/`
  (see the README's "Tour video" section) or mention it in the PR.

## Reporting bugs

Open an issue with your macOS version, Parseley version (Settings → General) and the
steps to reproduce. For copy/paste problems, say which app you copied from and pasted
into. Please don't paste real clipboard contents that might be private.
