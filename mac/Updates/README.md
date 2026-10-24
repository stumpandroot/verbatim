# Automatic updates (Sparkle)

The direct-download Mac app updates itself with [Sparkle 2](https://sparkle-project.org). The iPhone app doesn't use Sparkle.

The source repo (`stumpandroot/verbatim`) can be private. Everything the app and its users download comes from a separate public repo, [`stumpandroot/verbose-updates`](https://github.com/stumpandroot/verbose-updates), which holds only the feed and the DMGs, never source.

| What | URL |
|---|---|
| Feed (`SUFeedURL`) | `https://raw.githubusercontent.com/stumpandroot/verbose-updates/main/appcast.xml` |
| Newest beta DMG (newest build of `main`) | `https://github.com/stumpandroot/verbose-updates/releases/download/beta-latest/Verbose.dmg` |
| Newest stable DMG (newest `mac-v*` release) | `https://github.com/stumpandroot/verbose-updates/releases/latest/download/Verbose.dmg` |

How it works:

- CI (`.github/workflows/build-swift.yml`) signs each DMG with an EdDSA key in the `build` job. The `updates` job then runs `publish-update.sh`, which uploads the DMG to a release in verbose-updates and calls `publish-appcast.sh`. That script edits the feed with `appcast.py` and commits it to verbose-updates' `main` branch.
- The DMG goes up before the feed changes, so the feed never points at a missing file. Feed items point at the release for that build, never at `beta-latest`, whose file changes with every build.
- Each update is checked twice: Sparkle verifies the EdDSA signature, and macOS verifies the Developer ID signature and notarization.
- The source repo gets no releases or update branches. The `ci-screens` branch still carries CI screenshots and the owner's own DMG downloads.

## One-time setup

### Check that the source repo can keep its secrets

GitHub offers environments and environment secrets in private repos only on GitHub Pro, GitHub Team, or GitHub Enterprise. Required reviewers on an environment need a public repo or GitHub Enterprise. Before you make `stumpandroot/verbatim` private, confirm the plan covers the `release` environment; otherwise CI loses every signing, notarization, and update secret.

### Create the updates repo

1. Create the public repo `stumpandroot/verbose-updates` with a `main` branch and a README. CI adds `appcast.xml` to `main` on its first publish.
2. Protect `main`. In the repo's **Settings › Rules › Rulesets**, create a branch ruleset that targets the default branch, with **Restrict deletions** and **Block force pushes** turned on. Don't require pull requests or status checks; CI commits the feed directly.
3. Protect stable tags. Create a tag ruleset that targets `mac-v*`, with **Restrict updates** and **Restrict deletions** turned on. Don't restrict creations, because CI creates these tags. Leave `beta-*` tags unprotected, because CI deletes old betas and their tags.
4. Limit who can create releases. Anyone with write access can create or replace releases, so keep write access to the repo's owners: no outside collaborators and no team with write access. Turn off features the repo doesn't need, such as **Wikis**, **Issues**, and **Projects**.
5. Leave **immutable releases** off if the repo offers it. `beta-latest` replaces its `Verbose.dmg` on every build of `main`.

### Create the publishing token

1. On GitHub, open **Settings › Developer settings › Personal access tokens › Fine-grained tokens** and generate a token:
   - **Resource owner:** `stumpandroot`
   - **Repository access:** **Only select repositories**, with only `stumpandroot/verbose-updates`
   - **Repository permissions:** **Contents: Read and write** (Metadata: Read-only is added automatically)
   - **Expiration:** a date you'll remember to renew before
2. Store it as a secret of the `release` environment in the source repo:

   ```sh
   gh secret set UPDATES_TOKEN -R stumpandroot/verbatim --env release
   ```

   Paste the token when prompted. CI passes it only to the `updates` job's publish step.

### Create the signing keys

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

3. Export the private key, store it as a secret of the `release` environment (**Settings › Environments**; CI creates the environment on the first build of `main`), and delete the file:

   ```sh
   ./bin/generate_keys -x sparkle_private.key
   gh secret set SPARKLE_PRIVATE_KEY -R stumpandroot/verbatim --env release < sparkle_private.key
   rm -P sparkle_private.key
   ```

   The keychain copy is your backup. If you lose the private key, apps already installed can't verify updates anymore, and their users have to download a new version by hand.

4. Paste the public key into `mac/project.yml`, under the `Verbatim` target's `info` › `properties`:

   ```yaml
   SUPublicEDKey: "your-public-key"
   ```

   Commit the change and push it to `main`. Until this value is set, the app never starts the updater: no update checks run, no errors appear, and **Check for Updates…** stays dimmed.

CI also needs the Developer ID signing and notarization secrets (`MACOS_CERTIFICATE`, `APPLE_APP_PASSWORD`, and the rest; see the top of the workflow). Without a Developer ID-signed, notarized DMG, CI publishes no update.

Until `UPDATES_TOKEN` and `SPARKLE_PRIVATE_KEY` are both set, the `updates` job publishes nothing and leaves a notice on the run that names the missing secret. The build stays green.

## Channels

The feed holds at most two items:

| Item | Who gets it | Published by |
|---|---|---|
| Stable (no `<sparkle:channel>`) | Everyone | Pushing a tag such as `mac-v1.2.0` |
| Beta (`<sparkle:channel>beta</sparkle:channel>`) | Users with **Settings › General › Get beta builds** on | Every build of `main` (push or manual run); also prerelease tags such as `mac-v1.3.0-beta.1` |

- Builds of `main` are versioned `0.0.0`, and **Get beta builds** defaults to on in those builds, so your own builds follow the beta channel. Tagged releases default to off.
- Beta users also see the stable item. Sparkle offers whichever item has the higher build number (`sparkle:version`, which is the CI run number).
- Each build of `main` becomes a prerelease tagged `beta-<run number>` in verbose-updates, with `Verbose.dmg` attached. CI keeps the newest five and deletes older ones with their tags. The same DMG replaces `Verbose.dmg` on the `beta-latest` prerelease.
- Feature branches never publish updates.
- Release notes in verbose-updates name only the build or version, because that repo is public. Edit a release on GitHub to add notes.

## Cut a public release

1. Make sure `main` builds green with the version you want to ship.
2. Tag the commit in the source repo and push the tag:

   ```sh
   git tag mac-v1.2.0
   git push origin mac-v1.2.0
   ```

3. The workflow builds, signs, and notarizes the DMG. The `updates` job creates the release `mac-v1.2.0` in verbose-updates with `Verbose.dmg`, marks it as the latest release, and points the feed's stable item at it.
4. Check the release on [verbose-updates' releases page](https://github.com/stumpandroot/verbose-updates/releases) and the stable item in `appcast.xml` on its `main` branch.

A tag with a suffix, such as `mac-v1.3.0-beta.1`, becomes a prerelease and updates the beta item instead.

## Privacy

An update check sends a request to `raw.githubusercontent.com` (the feed) and, when an update is downloaded, to `github.com`. GitHub sees your IP address and Verbose's version in the request. Sparkle's system profile is turned off (`SUEnableSystemProfiling` is `false`), so no hardware or OS details are sent. You can turn off automatic checks in **Settings › General › Updates**.

## Test the scripts

`bash mac/tools/test-appcast.sh` tests `appcast.py`, then runs `publish-update.sh` and `publish-appcast.sh` against a local Git repo with stand-ins for `gh` and `curl`, so nothing reaches GitHub. The Linux logic tests in `check-swift.yml` run it on every branch push.

## Troubleshooting

- **The build fails at notarization after Sparkle was added.** `build.sh` signs Sparkle's nested code (the XPC services, `Autoupdate`, and `Updater.app`) one by one before the app. In the build log, find the `Sparkle signature:` lines. Each part must show `Authority=Developer ID Application: …`, your `TeamIdentifier`, a `Timestamp=` line, and `flags=0x10000(runtime)` on the `CodeDirectory` line. For notarization errors, run `xcrun notarytool log <submission id> --keychain-profile verbatim-notary` and look for paths inside `Sparkle.framework`.
- **No beta release appears.** Open the run's `updates` job. A notice in its first step names what's missing: `UPDATES_TOKEN`, `SPARKLE_PRIVATE_KEY`, or a Sparkle signature from the build. For a missing signature, find the build job's "Updates: sign the DMG for Sparkle" step; a warning there says why it skipped (no Developer ID signature or no notarization).
- **The publish step fails with `HTTP 401` or `Bad credentials`.** `UPDATES_TOKEN` expired or was revoked. Generate a new token as in [Create the publishing token](#create-the-publishing-token) and set the secret again.
- **The publish step says a URL "isn't downloadable without signing in".** verbose-updates is private, or the release didn't publish. The feed isn't changed when this check fails.
- **The app never offers an update.** Open `~/Library/Logs/Verbatim/native.log` and find the `updates:` line. `off (no SUPublicEDKey)` means step 4 of [Create the signing keys](#create-the-signing-keys) isn't done in that build. Also confirm that the feed's `sparkle:version` is higher than the installed build number, shown in **Settings › General › Updates**.
- **Sparkle reports a signature error.** The public key in `project.yml` doesn't match the private key in the `SPARKLE_PRIVATE_KEY` secret. Run `./bin/generate_keys -p` to print the public key for the key in your keychain.
