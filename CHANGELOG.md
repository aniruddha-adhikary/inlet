# Changelog

## 0.3.0 — first public release

- Single sandboxed macOS app (no helper processes): embedded sign-in, then runs from the menu bar.
- Sources: WhatsApp Web and Telegram Web K, both read from the web app's in-memory store.
- Siri AI answers from bridged messages natively; "search … in Chatbridge" is answered inside
  Siri by Apple's on-device model over the app's own index.
- Tapping a result opens the conversation at that message, with context.
- Message content encrypted at rest (AES-GCM, key in the keychain); per-chat "stop indexing";
  per-source disconnect-and-delete; erase everything.
- Declarative profiles with canary checks and quarantine.
