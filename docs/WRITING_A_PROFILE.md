# Writing a profile

A profile tells Inlet how to read one app surface. It is data, not code: a JSON file in
`profiles/`, validated at load time, shipped inside the signed app.

## The catalog entry

Before a profile can be used, the app has to exist in the catalog: `apps/<name>.json`.

```json
{
  "id": "net.whatsapp.web",
  "name": "WhatsApp",
  "kind": "messages",
  "status": "available",
  "symbol": "message.fill",
  "tint": "#25D366",
  "url": "https://web.whatsapp.com/",
  "allowedHosts": ["web.whatsapp.com"],
  "loginProbe": "... returns 'connected', 'login' or 'loading' ...",
  "needsStorePage": true
}
```

- `id` must match `app.id` in the profile.
- `kind` is what the app contributes: `messages` today; `notes`, `tasks`, `documents` are reserved.
- `status: "planned"` lists the app in the gallery as "Coming Later". It needs no `url`.
- `allowedHosts` confines the session: any other navigation opens in the default browser.
- `loginProbe` may only look at page structure. It must never read content.
- `symbol` is an SF Symbol. Do not ship another company's logo.

## Anatomy

```jsonc
{
  "profile": "example-web",            // name
  "profileVersion": 1,                 // several versions may coexist; highest applicable wins
  "status": "unverified",              // "verified" once checked against the live app
  "method": "page-store",              // or "dom"
  "app": { "id": "com.example.web", "name": "Example", "surface": "web" },
  "match": { "hosts": ["app.example.com"], "paths": ["/"], "versions": { "min": "2.0" } },
  "schema": "messages.message",        // a normalized schema from schemas/
  "store": { … } | "extract": { … },   // how to read, depending on method
  "canary": { "minItems": 1, "fillRate": { "sourceId": 1.0, "sentAt": 0.99, "body": 0.5 } },
  "deepLink": "https://app.example.com/"
}
```

## `method: "page-store"` — read the web app's own in-memory data

Preferred: it sees everything the app has loaded, with real ids, not just what is on screen.

- Source: either `"require": "<module>", "collection": "<name>"` (an app exposing a module
  loader, like WhatsApp Web) or `"root": "window", "path": "a.b.c", "depth": 2` (enumerate a plain
  object N levels deep, like Telegram Web K's mirrors).
- `where`: `{ "<path>": [allowed values] }` filters models.
- `fields`: each maps a schema field to a spec:
  `path` / `paths` (first non-null), `as: "string"` (stringify objects), `lookup`
  (`{ "collection" | "target": …, "paths": […] }` resolves an id to a name), `switch`/`cases`,
  `anyOf` (fallback chain), `join` + `sep`, `map`, `default`, `const`, `parse: "epochSeconds"`.

**The interpreter is read-only by construction.** It can resolve a module or path, enumerate, look
up by id and read properties. There is no syntax for calling a function, so a profile cannot send,
mark as read, or fetch history. `readers/tests/pagestore.test.mjs` fails if the reader ever calls
into the host app. Do not add a field spec that calls functions.

## `method: "dom"` — read the rendered page

Fallback when there is no reachable store. `extract.item` is a selector for one record;
`extract.fields` use `selector`, `get` (`text`, `attr:name`, `exists`, `matches:sel`), `regex` +
`group`, `map`, `parse` (`datetime` with `dateOrder`, `epochSeconds`). `extract.context` reads
page-level values (the open chat's name). Prefer roles and `data-*` attributes over class names.

## The canary

`fillRate` is the minimum fraction of visible records that must have each field. When a web app
changes, extraction quietly degrades; the canary turns that into a hard stop: a failing batch
stores **nothing**, and three failures in a row quarantine the profile
(`Inlet --release <profile@version>` lifts it). Set thresholds from real data, leaving room
for legitimately empty fields (media messages have no body).

## Identity

`sourceId` must be unique within the app and **stable**. If ids are per-chat, join them with the
chat id. Provide `senderId` so people are keyed by a stable id: display names resolve lazily and
change. If two profiles read the same app (store + DOM fallback), make them produce the same
`sourceId` so they address the same records.

## Workflow

1. Explore the live page in your browser's console. Look for a module loader, globals, or stable
   DOM hooks. Record *structure only* in the profile's `notes`.
2. Write the profile and a fake-store test in `readers/tests/`.
3. Add a sign-in descriptor in `SourceSession.catalog` (URL, allowed hosts, a login probe that
   reads structure only).
4. Run the app, connect, and check `Inlet --log-tail 30`: look at `canary=` and
   `update …: changed <fields>` (field names only) for churn.
5. Set `"status": "verified"` and note the date.

Only add sources that are real gaps: no Apple app can ingest the account, and the publisher has
not opened read access to Siri.
