# Releasing Inlet

A release is a notarized `Inlet.dmg` attached to a GitHub release. The README's download button
points at `releases/latest/download/Inlet.dmg`, so publishing a release is all it takes to ship.

## Each release

1. Bump `MARKETING_VERSION` in `app/Inlet.xcodeproj/project.pbxproj` (four places, same value).
2. Add a `## <version>` section at the top of `CHANGELOG.md`. It becomes the release notes verbatim,
   so write it for people who use the app.
3. Run the tests (see `AGENTS.md`), commit, and make sure you are on a clean `main`.
4. Check, then release:

```bash
./scripts/release.sh 0.6.0 --check
```

```bash
./scripts/release.sh 0.6.0
```

The script builds a Release archive, exports it with a Developer ID signature, notarizes and staples
the app and the DMG, and then **asks before it pushes anything**. After you confirm it pushes `main`,
pushes the tag `v<version>`, creates the GitHub release with `Inlet.dmg` and `Inlet.dmg.sha256`, and
finally downloads the published file again to confirm the checksum and the notarization ticket.

If it stops before publishing, nothing has left your Mac. The notarized DMG is in `dist/`.

## One-time setup on a new Mac

- **A paid Apple Developer Program team**, signed in to Xcode (Settings > Accounts). Signing is
  automatic: Xcode uses the team's cloud-managed Developer ID certificate, so no certificate needs
  to be created or installed by hand. A free personal team cannot produce a distributable build.
- **`app/Config/Local.xcconfig`** with your `DEVELOPMENT_TEAM` and `INLET_BUNDLE_ID`
  (copy `Local.xcconfig.example`). It is gitignored.
- **Notary credentials.** Create an app-specific password at account.apple.com, then store it in the
  keychain. The command prompts for the password:

```bash
xcrun notarytool store-credentials inlet-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
```

- **`gh`**, logged in (`gh auth login`), with push access to the repository.

## Things that will trip you up

- **Never change the bundle id of a published app.** It owns the sandbox container, the keychain key
  and the Siri index. A new id means every user loses their stored items and sign-ins.
- **Don't re-sign by hand.** Inlet's keychain and application-identifier entitlements need a
  Developer ID provisioning profile inside the app. Only the Xcode export embeds it; a plain
  `codesign --sign "Developer ID…"` produces an app that will not launch.
- **The DMG asset must be named `Inlet.dmg`.** GitHub's "latest download" link needs a fixed file
  name. The version lives in the tag, not the file name.
- **`security find-identity` will not list a Developer ID certificate.** It is cloud-managed. That is
  expected; judge by the export, not by the keychain.
- **If `git push` says "Permission denied (publickey)"**, your git is using SSH and the key is not
  loaded: run `ssh-add` and try again.
- **Notarization rejected?** `xcrun notarytool log <submission id> --keychain-profile inlet-notary`
  prints Apple's reasons.
- **Verify a DMG yourself** at any time:

```bash
xcrun stapler validate dist/Inlet.dmg
```

```bash
spctl --assess --type execute -v /Volumes/Inlet*/Inlet.app
```

  The second should say `accepted, source=Notarized Developer ID`.
