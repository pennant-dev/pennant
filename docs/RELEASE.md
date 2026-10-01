# Releasing Pennant

A Mac opens a downloaded app without warnings only when it is signed with a **Developer ID** certificate, built with
the **hardened runtime**, and **notarized** by Apple. `Scripts/release.sh` does all of it and leaves
`dist/Pennant-<version>.dmg`, `.zip` and `.tar.gz` with their checksums, ready to publish.

## Every release

1. Bump the version: `PennantVersion.string` in `Sources/PennantCore/Version.swift` and the Mac app's `MARKETING_VERSION`
   in `project.yml` (the script checks they match), and the Mac app's `CURRENT_PROJECT_VERSION`, which must increase.
2. Write `docs/release-notes/<version>.md`.
3. Run `Scripts/release.sh`. It runs the tests, builds the host for Apple silicon and Intel, archives a Release build
   with the hardened runtime, signs it for Developer ID, sends it to Apple's notary service, waits for approval (a few
   minutes), checks both signatures (the app and the Pennant Host helper inside it), the helper's entitlements, the
   stapled ticket and Gatekeeper's verdict, packs the DMG, the zip and the tarball with their checksums, writes the
   signed update feed, and moves the site's download button, version line and checksum to the new version.
4. Publish the GitHub release with the four files; the script prints the command. Every download of the app comes
   from there, the site's button and the updater included, so GitHub's download counts are the whole picture.
5. Commit the site change and push, then run `Scripts/deploy-site.sh`: the site, then the feed, once the release's
   archive is reachable.

## Updates (Sparkle)

Installed copies update themselves through [Sparkle](https://sparkle-project.org). The app carries the feed address
(`https://pennant.dev/appcast.xml`) and an EdDSA **public** key in its Info.plist (`SUPublicEDKey` in `project.yml`).
The matching **private** key is in the login keychain of the Mac that cuts releases, under the account `pennant`.
`Scripts/release.sh` signs each archive with it and rewrites `dist/updates/appcast.xml`, pointing each archive at the
GitHub release for its version; the feed itself lives at pennant.dev. `Scripts/deploy-site.sh` publishes the feed only
once the release's archive answers, so no installed copy is ever offered a file that isn't there.

- **The private key must be backed up.** Without it you cannot ship updates that installed copies accept. The backup
  lives in AWS Systems Manager Parameter Store as an encrypted SecureString (`/pennant/sparkle-ed25519-private-key`).
- The updater only offers a build whose `CURRENT_PROJECT_VERSION` is higher than the installed one; the release script
  refuses a build number that is already in the feed.
- People are asked on their second launch whether Pennant may check automatically. It then checks at most once a day
  and sends no system profile. Settings › General › Updates has the switches and Check Now; the app menu and the menu
  bar menu have Check for Updates.
- After an update the Pennant Host from before it may still be running (launchd keeps it alive). The app compares the
  host's build with its own and restarts the host once no task is running.
- Debug builds don't start the updater.

Restore the key on another Mac (the last line must print the public key in `project.yml`):

```sh
BIN=$(find .build-release .build-apps -type d -path "*Sparkle/bin" | head -1)
F="${TMPDIR:-/tmp/}pennant-sparkle.key"
aws ssm get-parameter --region us-east-1 --name /pennant/sparkle-ed25519-private-key --with-decryption \
  --query Parameter.Value --output text > "$F" && "$BIN/generate_keys" --account pennant -f "$F"
rm -f "$F"
"$BIN/generate_keys" --account pennant -p
```

Anyone with access to that parameter can sign updates that every installed copy of Pennant will accept. Keep the AWS
account locked down: use MFA, and do not grant `ssm:GetParameter` on `/pennant/*` to anything that does not cut releases.

## The two routes

**Xcode account (default).** Xcode's signed-in Apple ID signs with a *cloud-managed* Developer ID certificate and
uploads to the notary service, so nothing has to be in the keychain. Requirements: the team in
`Apps/Signing.local.xcconfig` (`DEVELOPMENT_TEAM = …`, git ignores the file) is in the paid Apple Developer Program,
and that Apple ID is signed in under Xcode › Settings › Accounts. Only the Account Holder or an Admin with
"cloud-managed Developer ID" access can sign this way. The disk image itself is not signed on this route; the app
inside is signed, notarized and stapled, which is what Gatekeeper checks.

**Local certificate.** Used automatically when the keychain holds a "Developer ID Application" certificate *and*
notarytool credentials are stored as `pennant-notary`. This route also signs and notarizes the disk image.

- Certificate: Xcode › Settings › Accounts › (team) › Manage Certificates… › + › Developer ID Application. Export a
  .p12 backup; Apple never gives the private key again.
- Credentials: make an app-specific password at appleid.apple.com, then
  `xcrun notarytool store-credentials pennant-notary --apple-id you@example.com --team-id <TEAM ID>`.

Force a route with `PENNANT_RELEASE_MODE=xcode` or `=local`.

## Notes

- The release build has a different signature from the development build that `Scripts/build-release.sh` puts in
  `dist/`. macOS ties Accessibility, Screen Recording and Automation to the signature, so a Mac that switches from one
  to the other is asked for those permissions again.
- The app and the helper run with the hardened runtime. The helper needs only the Apple events entitlement;
  Accessibility, Screen Recording and Input Monitoring are user permissions, not entitlements.
