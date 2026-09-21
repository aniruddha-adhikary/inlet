# Working on Inlet

Instructions for AI coding agents (and a fast orientation for people). Inlet is a sandboxed macOS 27
menu bar app that reads content from apps people sign in to and gives it to Siri and Spotlight as
App Schema entities. Read `README.md` for the product and `docs/HOW_SIRI_FINDS_YOUR_CONTENT.md` for
the hard-won rules about what Siri will actually use.

## Rules that are not negotiable

- **Read only.** No code path may send, edit, delete, or mark anything in a source app. In-page
  readers never call functions that hit the network (no loading earlier messages, no read receipts).
  Remote tool protocols (MCP) get a read-only allowlist.
- **Nothing leaves the Mac.** No servers, analytics, or crash uploaders. Stored content is sealed by
  `Vault`; new kinds of stored content must be too.
- **No personal content anywhere it can leak.** Logs, tests, docs, screenshots and commit messages
  contain counts, states and field names only. Use fictional names in examples. Never paste what a
  real account returned.
- **Never launch the app against real accounts in a loop.** Every automated or repeated launch uses
  `--offline` (no web session is loaded). Repeated reconnects have already logged a real account out.
- **UI tests run against the developer's real settings.** They must not add, rename or remove
  accounts, and must never confirm a destructive dialog.
- **Secrets are typed by the person, never handled by an agent**: app-specific passwords, API tokens,
  integration tokens. Ask them to run the command or paste into a secure field.
- Don't commit, push, tag or publish unless asked. `reference/`, `dist/` and
  `app/Config/Local.xcconfig` are never committed.

## Layout

| | |
| --- | --- |
| `app/Inlet/` | the app: `Core/` (vault, ingest, catalog, profiles), `Views/`, entities, intents, `Donor` (indexing), `SourceSession` (web sessions) |
| `app/InletUITests/` | UI tests and the App Intents index probes |
| `apps/` | catalog: one JSON per app Inlet can offer |
| `profiles/`, `schemas/` | how each app is read, and the normalized record shapes |
| `readers/` | JavaScript injected into web sessions, with tests |
| `dev/harness/` | optional Python harness for developing profiles |
| `app/Inlet/AppIcon.icon/` | the app icon: an Icon Composer document (`icon.json` + SVG layers) |
| `scripts/` | `install-app.sh`, `package.sh`, `release.sh` |

Accounts: everything stored is scoped by an account key (`<appID>` or `<appID>#<suffix>`), held in
the `app_id` column. `Account.appID(ofKey:)` strips the suffix.

## Build, run, test

`xcode-select` may point at the Command Line Tools, so set `DEVELOPER_DIR` for Xcode commands.

```bash
LAUNCH=0 ./scripts/install-app.sh
```

builds Debug and installs `/Applications/Inlet.app` without starting it (Siri ignores apps outside
an Applications folder). Drop `LAUNCH=0` to start it for real, once.

```bash
cd app && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Inlet.xcodeproj -scheme Inlet -derivedDataPath build -allowProvisioningUpdates test
```

```bash
node --test readers/tests/pagestore.test.mjs
```

```bash
cd dev/harness/host && uv run python -m unittest discover -s tests && uvx ruff check .
```

The UI tests drive the real screen: they can fail if someone is using the Mac. Re-run a single
failing UI test before believing it. Screenshots are attachments in the `.xcresult`; export them with
`xcrun xcresulttool export attachments`.

The sandbox container is unreadable from outside, so ask the app about itself:
`/Applications/Inlet.app/Contents/MacOS/Inlet --offline --status` (also `--log-tail N`,
`--verify-storage`, `--show-menu-bar-icon`, `--wipe-index`).

## Traps already paid for

- Indexed entities need the domain's real content type in `attributeSet` (messages:
  `public.message`) and `textContent`, or Siri ignores them. Bump `Donor.indexShapeVersion` whenever
  the donated shape changes.
- The Messages schema domain is all-or-nothing: the five refusing stubs in `ReadOnlyIntents.swift`
  must stay.
- The project defaults to `MainActor` isolation. A completion handler the system calls on a
  background queue (for example `ASWebAuthenticationSession`) must be built in a `nonisolated`
  helper, or the app traps when it fires.
- A SwiftUI binding backed by `@AppStorage` must only write real changes. An unconditional write
  re-invalidates the scene forever (100% CPU) and can persist a wrong value.
- The app is `LSUIElement`. Main-menu items are unreliable; anything important is also in the "?"
  toolbar menu. Windows can be opened with no live SwiftUI view via `AppModel.show(window:)`.
- `app/Inlet.xcodeproj` is hand-written with a synchronized root group: new Swift files under
  `app/Inlet/` are picked up automatically.
- The app icon is `app/Inlet/AppIcon.icon`, an Icon Composer document, not an `.appiconset`. The
  SVG layers carry the mark in white on a transparent canvas and nothing else: the system draws the
  rounded square, the gradient fill from `icon.json`, the glass, the shadow and every appearance
  (dark, tinted, clear). Baking a squircle, a background or a shadow into a layer breaks all of
  them. Render a change before trusting it, at a large size (small ones alias into false seams):
  `"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  app/Inlet/AppIcon.icon --export-image --output-file /tmp/icon.png --platform macOS --rendition
  Default --width 1024 --height 1024 --scale 1` (also `Dark`, `TintedLight`, `TintedDark`,
  `ClearLight`, `ClearDark`).

## Releasing

See [docs/RELEASING.md](docs/RELEASING.md). Short version: bump the version, add the CHANGELOG
section, commit, then `./scripts/release.sh <version>`. It asks before publishing.
