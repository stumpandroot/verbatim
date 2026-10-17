# Automatic updates (Sparkle)

The direct-download Mac app updates itself with [Sparkle 2](https://sparkle-project.org). The iPhone app doesn't use Sparkle.

- The app reads its feed from `https://raw.githubusercontent.com/stumpandroot/verbatim/updates/appcast.xml`, the `appcast.xml` file on the `updates` branch.
- CI (`.github/workflows/build-swift.yml`) signs each DMG with an EdDSA key and rewrites the feed. `appcast.py` edits the XML, and `publish-appcast.sh` commits it to the `updates` branch.
- Each update is checked twice: Sparkle verifies the EdDSA signature, and macOS verifies the Developer ID signature and notarization.

## One-time setup

You need a Mac. Run these commands in Terminal:

1. Download Sparkle's tools and unpack them:

   ```sh
   mkdir -p ~/sparkle-tools && cd ~/sparkle-tools
   curl -fLO https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
   tar -xJf Sparkle-2.10.0.tar.xz
   ```

2. Generate the key pair. The private key goes into your login keychain, and the command prints the public key:

   ```sh
   ./bin/generate_keys
   ```

   Copy the public key (a base64 string) from the output. If you already generated a key, the command prints the existing public key instead.

3. Export the private key, store it as a GitHub secret, and delete the file:

   ```sh
   ./bin/generate_keys -x sparkle_private.key
   gh secret set SPARKLE_PRIVATE_KEY -R stumpandroot/verbatim < sparkle_private.key
   rm -P sparkle_private.key
   ```

   The keychain copy is your backup. If you lose the private key, apps already installed can't verify updates anymore, and their users have to download a new version by hand.

4. Paste the public key into `mac/project.yml`, under the `Verbatim` target's `info` › `properties`:

   ```yaml
   SUPublicEDKey: "your-public-key"
   ```

   Commit the change and push it to `main`. Until this value is set, the app never starts the updater: no update checks run, no errors appear, and "Check for Updates…" stays dimmed.

CI also needs the Developer ID signing and notarization secrets (`MACOS_CERTIFICATE`, `APPLE_APP_PASSWORD`, and the rest; see the top of the workflow). Without a Developer ID-signed, notarized DMG, CI publishes no update.

## Channels

The feed holds at most two items:

| Item | Who gets it | Published by |
|---|---|---|
| Stable (no `<sparkle:channel>`) | Everyone | Pushing a tag such as `mac-v1.2.0` |
| Beta (`<sparkle:channel>beta</sparkle:channel>`) | Users with **Settings › General › Get beta builds** on | Every build of `main` (push or manual run); also prerelease tags such as `mac-v1.3.0-beta.1` |

- Builds of `main` are versioned `0.0.0`, and "Get beta builds" defaults to on in those builds, so your own builds follow the beta channel. Tagged releases default to off.
- Beta users also see the stable item. Sparkle offers whichever item has the higher build number (`sparkle:version`, which is the CI run number).
- Each beta build becomes a GitHub prerelease tagged `beta-<run number>`, with the DMG attached. CI keeps the newest five and deletes older ones with their tags.
- Feature branches never publish updates.

## Cut a public release

1. Make sure `main` builds green with the version you want to ship.
2. Tag the commit and push the tag:

   ```sh
   git tag mac-v1.2.0
   git push origin mac-v1.2.0
   ```

3. The workflow builds, signs, and notarizes the DMG. The `release` job publishes the GitHub release, then updates the stable item in the appcast to point at `Verbatim-universal.dmg` on that release.
4. Check the result in `appcast.xml` on the `updates` branch.

A tag with a suffix, such as `mac-v1.3.0-beta.1`, becomes a GitHub prerelease and updates the beta item instead.

## Privacy

An update check sends a request to `raw.githubusercontent.com` (the feed) and, when an update is downloaded, to `github.com`. GitHub sees your IP address and Verbatim's version in the request. Sparkle's system profile is turned off (`SUEnableSystemProfiling` is `false`), so no hardware or OS details are sent. You can turn off automatic checks in **Settings › General › Updates**.

## Troubleshooting

- **The build fails at notarization after Sparkle was added.** `build.sh` signs Sparkle's nested code (the XPC services, `Autoupdate`, and `Updater.app`) one by one before the app. In the build log, find the `Sparkle signature:` lines. Each part must show `Authority=Developer ID Application: …`, your `TeamIdentifier`, a `Timestamp=` line, and `flags=0x10000(runtime)` on the `CodeDirectory` line. For notarization errors, run `xcrun notarytool log <submission id> --keychain-profile verbatim-notary` and look for paths inside `Sparkle.framework`.
- **No beta release appears.** Find the "Updates: sign the DMG for Sparkle" step in the run. A warning there says why it skipped: no Developer ID signature or no notarization. If the step didn't run, check that `SPARKLE_PRIVATE_KEY` is set and the run is on `main`.
- **The app never offers an update.** Open `~/Library/Logs/Verbatim/native.log` and find the `updates:` line. `off (no SUPublicEDKey)` means step 4 of the setup isn't done in that build. Also confirm that the feed's `sparkle:version` is higher than the installed build number, shown in **Settings › General › Updates**.
- **Sparkle reports a signature error.** The public key in `project.yml` doesn't match the private key in the `SPARKLE_PRIVATE_KEY` secret. Run `./bin/generate_keys -p` to print the public key for the key in your keychain.
