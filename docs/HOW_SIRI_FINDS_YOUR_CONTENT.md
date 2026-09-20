# What it actually takes for Siri AI to answer from a third-party app (macOS 27)

Apple's documentation and sample apps describe the App Schemas API, but following them alone
did not get Siri to answer questions from our indexed content — and Apple's own samples
(UnicornChat, CometCal) did not manage it either when their windows were closed. These are the
requirements we found by experiment and by reading system logs. Treat them as observations of
macOS 27.0, not as a contract.

## The checklist

1. **Give indexed entities the domain's real content type.** *(the one that mattered most)*
   `IndexedEntity` items are indexed with `contentType = com.apple.appintents.entity`. Siri's
   message-scoped retrieval filters on `kMDItemContentTypeTree = "public.message"`, so those items
   are invisible to it. Set the type in your entity's `attributeSet`:

   ```swift
   var attributeSet: CSSearchableItemAttributeSet {
       let set = defaultAttributeSet
       set.contentType = UTType.message.identifier   // "public.message"
       set.textContent = text                        // the default set only carries the display title
       set.authorNames = [sender]
       set.contentCreationDate = date
       set.containerTitle = chatName
       return set
   }
   ```

   We found this because `SpotlightSearchTool` (below) prints the query it compiles. The same
   presumably applies to other domains (`public.calendar-event`, `public.contact`, …).

2. **Index the text yourself.** The default attribute set contains only what
   `displayRepresentation` provides. Without `textContent`, nothing about the body is searchable.

3. **Install the app in an Applications folder.** Run from a build directory, Siri says
   *"I couldn't find an app named …"*.

4. **Have a real code-signing identity.** An ad-hoc signed app has no application identifier.

5. **Declare an `AppShortcutsProvider`.** Without one, the App Intents registry (`linkd`) logs
   *"does not have AppShortcuts, marking as processed"* and Siri cannot resolve the app's name.
   Siri AI's planner does not route free-form requests to your shortcut phrases, though: it routes
   through **schema intents** (`.system.searchInApp`, `.system.open`, the domain's intents).

6. **Adopt the whole domain if it is an all-or-nothing domain.** Messages, Mail and Clock require
   every schema in the group. Xcode does not warn when you adopt only the entities. A read-only app
   can satisfy this with intents whose `perform()` throws.

7. **Index the supporting entities too** (people, conversations), with queries that really resolve
   them, and make the message body the display title — as Apple's UnicornChat does.

8. **Answer reindex requests.** Implement `IndexedEntityQuery` and a `CSSearchableIndexDelegate`.
   The system asked for a full reindex within two seconds of our app being able to receive it.

9. **Use a named index** (`CSSearchableIndex(name:)`); Apple's docs call the default index
   "for prototyping".

10. **Don't pick an app name containing "Siri".** It cannot be addressed by voice.

## Three routes by which Siri reaches third-party content

| Route | Works when | Notes |
| --- | --- | --- |
| **Index retrieval** | items are typed for their domain (see 1) | Siri composes its own answer and shows its entity card |
| **On-screen awareness** | the window is visible and rows carry `.appEntityIdentifier(...)` | how Apple's samples get read; nothing to do with the index |
| **Schema intents** | the user names the app ("search for X in App") | `.system.searchInApp` must set `openAppWhenRun = true`; a windowless (`LSUIElement`) app makes that invisible, and the intent can return a dialog |

## Answering with Apple's on-device model

`SpotlightSearchTool` (framework overlay `_CoreSpotlight_FoundationModels`, macOS/iOS 27) gives a
`LanguageModelSession` a tool that searches **your app's own** Core Spotlight index. It works fully
on device, and it logs the Spotlight query it compiles — the best debugging aid we found.

## Debugging tools that exist

- `/usr/bin/log show --info --debug --predicate 'process == "linkd"'` — the App Intents registry.
  (In zsh, `log` may be a shell builtin: use the full path.) Also useful: `searchtoold` (Siri's
  search tool: it logs its eligibility filter, `_kMDItemBundleID="com.apple.*" ||
  _kMDItemAppEntitySchema=* || …`), `intelligencecontextd` (on-screen fragments per app),
  `spotlightknowledged.updater` (reindex jobs). Third-party bundle ids and all query text are
  redacted as `<private>`.
- `AppIntentsTesting`: `definitions.entities["X"].spotlightQuery("…")` and `.entities(matching:)`
  query the way the system does. The UI test bundle must be signed by the same team as the app,
  and it can only inspect its own host app.
- `Metadata.appintents/extract.actionsdata` in the built app shows what the system will register.
- `mdfind` cannot see any app's Core Spotlight items; it is not a valid check.

## Red herrings (we chased all of these)

- `SetStoreUpdateService … Not trusting process … (validation category N)` and
  `Set existence required and no set exists, skipping donation`: logged for every third-party app,
  including Apple's samples and Developer ID apps. Not the blocker.
- `[SearchTool] isAppEntitySearch=0`: stayed 0 even when retrieval from our index worked.
- The embedding backlog on a freshly enabled Mac, per-app Siri settings, sandboxing, app category.
