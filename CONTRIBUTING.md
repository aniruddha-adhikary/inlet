# Contributing

Thanks for helping. The most useful contributions are **profiles for apps Siri can't read yet**
and **fixes when a web app changes and a profile breaks**.

## Ground rules

- **Read-only, always.** No change may give Inlet a way to send, edit, delete, react, mark as
  read, or trigger network requests in a source app. The in-page reader must stay a property
  reader; its test asserts it makes zero calls into the host app.
- **No message content in logs, tests, issues or commits.** Use fictional fixtures. When reporting
  a broken profile, share structure (attribute names, object keys, counts), never text or names.
- **No new runtime dependencies** without discussion. The app uses only Apple frameworks; the
  readers are plain JavaScript; the dev harness is Python's standard library.
- **Real gaps only.** Don't add a source that an Apple app can already ingest (Mail for Gmail,
  Calendar for Google Calendar) or whose publisher already exposes read access to Siri.

## Setup

Requirements: macOS 27, Xcode 27, an Apple ID (a free personal team is enough), Node 24+ for the
reader tests, and optionally [uv](https://docs.astral.sh/uv/) for the browser dev harness.

```bash
cp app/Config/Local.xcconfig.example app/Config/Local.xcconfig
```

Edit `Local.xcconfig` with your team id and a bundle id of your own, then:

```bash
./scripts/install-app.sh
```

Siri only sees apps installed in an Applications folder, which is why the script installs there.

## Tests

```bash
node --test readers/tests/pagestore.test.mjs
```

```bash
cd app && xcodebuild -project Inlet.xcodeproj -scheme Inlet -configuration Debug -derivedDataPath build -allowProvisioningUpdates test
```

```bash
cd dev/harness/host && uv run python -m unittest discover -s tests
```

The UI tests drive the real app and use Apple's AppIntentsTesting to query entities the way Siri
does. They seed fictional data and remove it afterwards. Re-run `install-app.sh` after them.

## Adding an app

See [docs/WRITING_A_PROFILE.md](docs/WRITING_A_PROFILE.md). A pull request for a new app should
include the catalog entry (`apps/<name>.json`), the profile, a fake-store test, and a note on how
you verified it (without sharing any content). No Swift changes should be needed.

The UI tests launch the app with `--offline`, so they never touch a real account. Keep it that way.

## Style

Swift 6 with main-actor default isolation; match the surrounding code; comments explain *why*.
JavaScript without a build step. Run `uvx ruff check` and `uvx ruff format` in the harness.
