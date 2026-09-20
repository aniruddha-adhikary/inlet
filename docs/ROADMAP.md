# Roadmap and known gaps

## Recorded gaps

### 1. Tapping a result: jump into the real app
Done: a tap opens the conversation inside Chatbridge at that message, with its neighbours, rows
annotated for on-screen awareness. Still open: landing in the *real* app. `whatsapp://send?phone=…`
needs a phone JID (LID-only chats don't expose one); `tg://` links need a username or user id; and
steering the embedded web session to a chat would need a navigation-only page action, a deliberate
exception to "no page calls" that must stay incapable of sending. Probably a per-source choice.

### 2. Telegram Web A
`telegram-web-k@2` (Web K) is verified live. Web A exposes no state in production builds; supporting it
would need a read-only IndexedDB source in the interpreter.

### 3. Distribution
No Developer ID certificate yet, so the DMG is development-signed and not notarized. After that:
auto-update (Sparkle or similar — a new dependency, to be decided), crash/diagnostic export that
contains no content.

### 4. Reader limits
- Only messages the web app has loaded (WhatsApp: recent per chat + any chat opened). No history backfill by design.
- Deletions/unsends aren't mirrored (absence from a window ≠ deleted).
- Media: captions only. No attachments, voice notes, reactions, replies (`referencedMessage`).
- The hidden web view can be throttled by macOS; long idle periods may delay syncing.

### 5. On-device answers
The small on-device model tends to treat a person named in the question as the *author* filter,
and sometimes reports the chat title wrongly. Options: a two-pass search (retry without author),
a custom `ContactResolver`, or Private Cloud Compute as an explicit opt-in (leaves the device).

### 6. Privacy controls
Done: per-chat "stop indexing" (deletes and blocks), per-source disconnect-and-delete, erase
everything. Still missing: "pause syncing", a retention limit (e.g. keep 90 days), and a first-run
consent screen that states plainly what is read and where it goes.

## Next sources (only real gaps: no Apple app can ingest them, publisher hasn't opened reads)
Signal (no web client → needs a different adapter), Slack, Discord, Microsoft Teams, Instagram/Messenger DMs.
Each should be a profile + a login descriptor. Native-app adapters (`sqlite`, `accessibility`)
conflict with the sandbox and need a separate helper with user-granted access.

## Generalising beyond messages
Give indexed entities the domain's real content type, not just the schema:
`public.message`, `public.calendar-event`, `public.contact`, … This was the difference between
"indexed but invisible to Siri" and "Siri answers from it".

## Regression checks after each macOS update
1. Ask Siri an un-named question about a bridged message.
2. `Chatbridge --status` and `--verify-storage`.
3. UI test suite (AppIntentsTesting) and `node --test`.
