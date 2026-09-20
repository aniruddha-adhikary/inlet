# Changelog

## 0.5.0: accounts, Settings, Help

- Any number of accounts per app (two WhatsApps, three Telegrams). Each has its own isolated web
  session, its own stored items and its own settings, and a name you choose. Siri uses the name
  ("WhatsApp Work"). Existing sign-ins carry over as the first account of their app.
- Settings (Inlet > Settings, or the "?" button): show or hide the menu bar icon, open at login.
  With the icon hidden, opening Inlet shows its window. `--show-menu-bar-icon` brings it back.
- Inlet Help: a built-in help window with short topics.
- About Inlet: version, author, license.
- The Privacy pane no longer says "Never the cloud".

## 0.4.0: Inlet

The app is now called **Inlet** (it was Chatbridge). It is a general way to bring content from
apps into Siri and Spotlight, not only chats. What you already stored carries over.

- New Mac-style window, modelled on System Settings: your apps in a sidebar, one pane per app, Privacy.
- Apps come from a catalog (`apps/*.json`). "Add App" is a searchable gallery, so the list can grow
  without interface changes. Add, pause, and remove apps whenever you like.
- Per app: "Available to Siri and Spotlight" (pause without signing out), "Keep" (Forever, One Year,
  30 Days), hidden chats, Remove App.
- Welcome screen with the privacy promise before any sign-in, a three-step tour, and a permanent
  Privacy pane with "See What's Stored" and "Erase All Data".
- No statistics in the main window. Counts, reader health, and the log live in Help > Diagnostics.
- Sign-in windows say who you are signing in to, and never appear on their own. If an app needs
  you again, the menu bar icon says so.
- The window gets a Dock icon and menus while it is open; otherwise Inlet stays in the menu bar.
- `--offline` launch argument: never loads a web session. Every automated test uses it.

## 0.3.0: first public release (as Chatbridge)

- Single sandboxed macOS app (no helper processes): embedded sign-in, then runs from the menu bar.
- Sources: WhatsApp Web and Telegram Web K, both read from the web app's in-memory store.
- Siri AI answers from bridged messages natively; "search … in Inlet" is answered inside
  Siri by Apple's on-device model over the app's own index.
- Tapping a result opens the conversation at that message, with context.
- Message content encrypted at rest (AES-GCM, key in the keychain); per-chat "stop indexing";
  per-source disconnect-and-delete; erase everything.
- Declarative profiles with canary checks and quarantine.
