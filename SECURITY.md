# Security model

Inlet reads your private conversations so Siri and Spotlight can find them. That makes
it a high-value target, so the design goal is: **read-only, on this Mac only, least privilege,
and erasable.**

## What it can and cannot do

| | |
| --- | --- |
| **Read** | Messages the source web app has already loaded, via declarative profiles. |
| **Never write** | No code path sends, edits, deletes, reacts, marks as read, or fetches history. The in-page reader can only resolve an object, enumerate it and read properties (`readers/pagestore.js`; enforced by a test that fails if the reader calls any function of the host app). The five Messages-domain intents Apple requires are present only as stubs that throw "read-only" (`ReadOnlyIntents.swift`). |
| **Network** | Only the embedded web sessions talk to the network, and only to their own service. Inlet itself makes no network requests and has no server component. The on-device Apple model answers questions locally; Private Cloud Compute is not used. |

## Controls

- **App Sandbox + Hardened Runtime.** Entitlements are the minimum: sandbox, outgoing network
  (for the web sessions), and the app's own keychain group. No file access outside the container,
  no Apple Events, no camera/microphone/contacts. macOS also blocks other processes from reading
  the container (`~/Library/Containers/<your bundle id>`).
- **Encryption at rest.** Message content is sealed with AES-256-GCM before it touches SQLite.
  The key is random, generated on first launch, stored in the data-protection keychain as
  *this device only*, never synced. Content hashes are HMACs under the same key, so a stolen
  database can't be used to test guesses about what a message says. Clear columns hold only ids,
  hashes, timestamps and bookkeeping. SQLite runs with `secure_delete`.
- **File permissions.** Data directory `0700`, database and log `0600`, excluded from backups.
- **Web session containment.** Each source's window may only navigate to its own host; other
  links open in the default browser; pop-ups are refused. Scripts that talk to the app run in an
  isolated content world; only the store reader runs in the page's world. The message handler
  accepts calls only from the source's own HTTPS origin and main frame, and a page can only
  submit records for profiles that belong to its origin.
- **Integrity.** Profiles and schemas ship inside the signed bundle; every stored record carries
  the profile's SHA-256. A canary judges each read; on failure nothing is stored, and three
  failures quarantine the profile.
- **Logging.** The diagnostic log never contains message text, names or search words: only
  counts, sizes, states and profile keys.
- **Erasure.** "Disconnect and delete" removes one source's web session, stored messages and
  index entries. "Erase everything" additionally clears the whole index and destroys the key.

## Verify it yourself

```bash
/Applications/Inlet.app/Contents/MacOS/Inlet --verify-storage
```

```bash
codesign -d --entitlements - /Applications/Inlet.app
```

## Known limits

- Content donated to Spotlight is stored by macOS in its own index, outside Inlet's
  encryption. That is inherent to making it searchable by Siri; "Erase everything" removes it.
- Siri AI shows on-screen content to the assistant; an open Inlet window is visible to it.
- Reading a web client this way is outside the services' terms of use. It is passive and
  single-user, but it is unsupported and can break when the web apps change.
- Distribution builds must be signed with a Developer ID and notarized (`scripts/package.sh`);
  the current DMG is development-signed.

## Reporting a vulnerability

Please don't open a public issue for a security problem. Use the repository's private
**Security advisories** ("Report a vulnerability") so it can be fixed before disclosure. Include
steps to reproduce; never include real message content.
