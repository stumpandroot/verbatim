# App Store builds

One build setting, `VERBATIM_APP_STORE`, decides whether an iPhone build uses features that App Review may reject. Your own builds (Debug, Release, CI, `build.sh`) keep it `NO` and keep every feature. App Store and TestFlight builds set it to `YES`.

The app's public name is **Verbose** (Home Screen, App Store listing, keyboard list, share sheet, widgets, and permission prompts); "Verbatim" is the internal codename. Bundle IDs (`co.stumpandroot.verbatim*`), the App Group, the iCloud container, the SKU, targets, and schemes keep the codename. In App Store Connect, the app name is Verbose and the subtitle or promotional text can use the tagline "Go ahead. Be verbose."

## Make an App Store build

1. Run `xcodegen generate` in `mac/`.
1. In Xcode, choose the **VerbatimPhone App Store** scheme.
1. Choose **Product › Archive**. The scheme archives with the **AppStore** configuration, which is Release plus `VERBATIM_APP_STORE=YES`.
1. Upload the archive from the Organizer.

From the command line, pass the setting to any configuration:

```sh
xcodebuild -project Verbatim.xcodeproj -scheme "VerbatimPhone App Store" -configuration AppStore archive
# or, for a quick compile check of any configuration:
xcodebuild -project Verbatim.xcodeproj -scheme VerbatimPhone -configuration Debug VERBATIM_APP_STORE=YES build
```

## TestFlight builds from CI

The TestFlight upload in `.github/workflows/build-swift.yml` (main builds only, for internal testers) archives the AppStore configuration with one exception: it also defines `YOUTUBE_ON_DEVICE`, by passing `VERBATIM_PHONE_CONDITIONS_YES="APP_STORE YOUTUBE_ON_DEVICE"`, so YouTube links transcribe on the iPhone. Apple doesn't review builds for internal testers.

- Don't add these builds to an external testing group or submit them for App Review. Guideline 5.2.3 makes YouTube downloads a rejection risk.
- To submit, archive the **VerbatimPhone App Store** scheme as described above, without the override, and upload that build.

### TestFlight signing

The job signs without creating a certificate and without signing secrets beyond the App Store Connect API key:

1. **Archive, ad hoc signed.** `xcodebuild archive` runs with `CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY=- AD_HOC_CODE_SIGNING_ALLOWED=YES` and no API key. These are the flags Xcode Cloud passes to its own archive step ([Xcode Cloud archive log](https://developer.apple.com/forums/thread/740025), [the same flags on GitHub Actions](https://developer.apple.com/forums/thread/756119)). Ad hoc signing needs no certificate or profile, and it still embeds each target's entitlements file in its signature.
1. **Check entitlements.** The job reads the signature of `Verbatim.app` and its four extensions in the archive. Each must carry the App Group `group.co.stumpandroot.verbatim.ios`, and the app must also carry the iCloud container. If one doesn't, the job stops before uploading.
1. **Export and upload.** `xcodebuild -exportArchive` (method `app-store-connect`, automatic signing, `-allowProvisioningUpdates` with the API key) creates or updates the App Store profiles and re-signs every binary with Apple's cloud-managed Apple Distribution certificate, keeping the entitlements from step 1. Xcode cloud signs when no local distribution certificate is found ([Apple: cloud-managed certificates](https://developer.apple.com/help/account/create-certificates/cloud-managed-certificates/)). Cloud signing needs an API key with the Admin role.

Before this change the archive used automatic development signing. A fresh runner has an empty keychain, so Xcode created an Apple Development certificate every run, which only that runner could use, until the account reached its limit ("Choose a certificate to revoke. Your account has reached the maximum number of certificates"). Others hit the same behavior on GitHub Actions and Bitrise ([Apple forums](https://developer.apple.com/forums/thread/695759), [Bitrise](https://discuss.bitrise.io/t/new-development-certificates-created-with-every-build/21068)).

Options considered and not used:

| Option | Why not |
|---|---|
| Archive with `CODE_SIGN_IDENTITY="Apple Distribution"` and automatic signing | Automatic signing rejects it ("is automatically signed for development, but a conflicting code signing identity Apple Distribution has been manually specified", [Apple forums](https://developer.apple.com/forums/thread/713058)). Even where accepted, it would need a distribution private key on the runner, so Xcode would create distribution certificates instead. |
| Archive unsigned (`CODE_SIGNING_ALLOWED=NO`) and let the export sign | Unsigned binaries carry no entitlements, and the export doesn't add them back: builds lose App Groups, iCloud, and push ([Apple forums](https://developer.apple.com/forums/thread/671800), [Apple forums](https://developer.apple.com/forums/thread/756119)). |
| Manual signing with an Apple Distribution .p12 and five App Store profiles as secrets | Works, but needs six secrets and new profiles whenever a capability changes or a profile expires. |
| One development certificate stored as a secret | Works ([Bitrise](https://discuss.bitrise.io/t/new-development-certificates-created-with-every-build/21068)). Kept as the fallback below. |

The job never revokes a certificate; that could revoke one of your own.

#### If the job reports the certificate limit

1. Open [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/certificates/list).
1. Revoke the Apple Development certificates that CI created: their creator reads "Created via API". Keep the ones for your own Macs.
1. Rerun the TestFlight job, or push to main.

After this change, the TestFlight job shouldn't create certificates. If the list grows again, something else is creating them.

#### Fallback: one development certificate

Use this only if the ad hoc archive fails on a runner, or the entitlements check reports a missing entitlement. With `IOS_DEV_CERTIFICATE` set, the job imports that certificate into a temporary keychain, archives with automatic development signing and the API key (the old command, which now finds a certificate and doesn't create one), and deletes the keychain when the step ends. The export is unchanged.

1. In Certificates, Identifiers & Profiles, create one **Apple Development** certificate for CI from a certificate signing request (Keychain Access › Certificate Assistant › Request a Certificate From a Certificate Authority).
1. Double-click the downloaded certificate to install it, then in Keychain Access › My Certificates, export it with its private key as `AppleDevelopment.p12`, with a password.
1. In the folder that holds the file, run:

   ```sh
   base64 -i AppleDevelopment.p12 | gh secret set IOS_DEV_CERTIFICATE --env release -R stumpandroot/verbatim
   gh secret set IOS_DEV_CERTIFICATE_PASSWORD --env release -R stumpandroot/verbatim
   ```

   The second command asks for the value; paste the .p12 password.
1. Delete `AppleDevelopment.p12`.

To go back to the ad hoc archive, run `gh secret delete IOS_DEV_CERTIFICATE --env release -R stumpandroot/verbatim`.

Quick check (`.github/workflows/check-swift.yml`) compiles the iPhone app both ways on every push to `integrate`, and on every branch push that changes a file the iPhone app or its extensions build from. The App Store pass confirms that `APP_STORE` is defined, that `YOUTUBE_ON_DEVICE` isn't, and that none of the private names below are left in the app (`_hostBundleID`, `_hostApplicationBundleIdentifier`, `_systemNavigationAction`, `LSApplicationWorkspace`, `openApplicationWithBundleID`). It no longer rejects the keyboard's `openURL:options:completionHandler:` selector; see the next section.

### Apple Watch

The iPhone app embeds the Apple Watch app (`VerbatimWatch`, bundle ID `co.stumpandroot.verbatim.ios.watchkitapp`) and its complications (`co.stumpandroot.verbatim.ios.watchkitapp.widgets`), DESIGN.md §20. Both carry the App Group `group.co.stumpandroot.verbatim.ios`. The export's automatic signing registers the two bundle IDs and their profiles with the API key, the same way it handles the extensions.

One switch leaves the watch app out: `VERBOSE_WATCH=NO bash tools/generate-project.sh` generates the project without the iPhone app's dependency on it. The TestFlight job tries with the watch app first. If the archive, the entitlement check, or the upload fails, it generates the project again with `VERBOSE_WATCH=NO`, archives and uploads once more, and prints a warning that the build left the watch app out. When that warning shows:

1. Open the job's warnings. The first try's errors say what failed, such as a profile that couldn't be created for a watch bundle ID.
1. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list), check that both bundle IDs exist with the App Groups capability and the group `group.co.stumpandroot.verbatim.ios`. Create them if they don't.
1. Push to main again. The next build includes the watch app.

The App Store listing needs Apple Watch screenshots before a build with the watch app goes to App Review.

## Accepted risk: the keyboard opens Verbose (guideline 4.4.1)

Guideline 4.4.1 says keyboard extensions may not launch apps other than Settings. Verbose's keyboard opens Verbose anyway, in every build, App Store and TestFlight included, the way Wispr Flow's does: Start a session (and the record button with no session) opens `verbatim://session?start=1&request=…`, which starts the session. Tim decided this in October 2026, knowing it risks rejection, because the alternative (a card with three text instructions) was bad to use.

- The code is `KeyboardViewController.openContainingApp`: it walks the responder chain to the extension's `UIApplication` and sends `openURL:options:completionHandler:` by selector. It names no private class.
- App Store builds still compile out every private API that automated review detects: the host bundle ID read and the automatic switch back (`_systemNavigationAction`, `LSApplicationWorkspace`). So after the session starts, Verbose stays in front and its start screen shows how to go back: swipe right along the bottom edge, or tap "◀ <app>" at the top left. The full coach card shows for the first five session starts, then a one-line reminder.
- **If App Review rejects the app under 4.4.1, remove this first.** In `openContainingApp`, put the body back under `#if APP_STORE … return false … #else … #endif`; in `Distribution.abilities(appStore:)`, set `keyboardOpensVerbatim: !appStore`; and in `check-swift.yml`, add the `openURL:options:completionHandler:` check on `VerbatimKeyboard.appex` back. When the keyboard can't open Verbose, Home shows the three other ways to start a session (`StartCard.instructions`), the same fallback it shows when iOS refuses to open the link.

## What the flag changes

`VERBATIM_APP_STORE=YES` defines the `APP_STORE` compilation condition in the app, the keyboard, and the widget extension (`project.yml` picks it with `$(VERBATIM_*_CONDITIONS_$(VERBATIM_APP_STORE))`). Code under `#if APP_STORE` is compiled out, not only switched off at run time. `Distribution.abilities(appStore:)` in `VerbatimKeyboard/KeyboardFormat.swift` describes the result.

| Feature | Your builds | App Store builds |
|---|---|---|
| Keyboard reads the host app's bundle ID (`_hostBundleID`, `_hostApplicationBundleIdentifier` in `KeyboardViewController.hostBundleID()`) | On | Compiled out; returns nil. The format chip's Auto infers from the text field instead. |
| Keyboard opens Verbose to start a session (`openURL:options:completionHandler:` through the responder chain in `KeyboardViewController.openContainingApp`) | On | On (accepted 4.4.1 risk, above). If the link doesn't open, the keyboard shows the three other ways to start a session. |
| App switches back to the app you came from (`_systemNavigationAction` breadcrumb and `LSApplicationWorkspace.openApplicationWithBundleID:` in `KeyboardSession.returnToHostApp`) | On | Compiled out; returns "not available in App Store builds". The start screen shows how to go back (the coach card). |
| YouTube audio on the iPhone (`YOUTUBE_ON_DEVICE`, YouTubeKit in `PhoneLinkFetcher`) | On | Not defined. YouTube links go to the Mac's Queue, like any site the iPhone can't fetch. YouTubeKit stays linked, but nothing calls it; remove the package dependency in `project.yml` to drop it from the binary. |
| Settings › Keyboard › Start dictating when you come back | Shown | Shown. The first tap opens Verbose and starts listening, so you can talk as soon as you're back. |

## Starting a session in App Store builds

iOS doesn't let an app start recording from the background, so each of these opens Verbose for a moment, turns on the microphone, and then shows "Your session is on" with how to go back to your app:

- **The Verbose keyboard:** Start a session on the keyboard's Home, or the record button with no session (accepted 4.4.1 risk, above).

- **Control Center** (iOS 18 and later): the Verbose session switch (`StartSessionControl`, `SetSessionIntent`). Off ends the session without opening Verbose.
- **Action button** (the recording ribbon): the Verbose action control or the Action button App Shortcut (`ActionButtonIntent`), which does what Settings › Action button says (Dictate by default; also Record a voice note, Live captions, and What's playing). On iOS 18 and later it's also an `AudioRecordingIntent`, so Record a voice note tries to start in place behind its Live Activity and opens Verbose when iOS refuses. The first press opens Verbose, turns on the microphone, and starts a take; while the session is on, each press starts or stops a take without opening Verbose (`DictateIntent` and friends are `LiveActivityIntent`s that run in the app's process).
- **Shortcuts and Siri:** Dictate (`DictateIntent`) and Start dictation session (`StartKeyboardSessionIntent`), in `VerbatimAppShortcuts`.
- **Lock Screen:** the Verbose widget, which opens `verbatim://session?start=1&from=widget`.
- **Verbose:** Settings › Keyboard › Start keyboard session.
- **Restart** on the Session ended Live Activity (Dynamic Island and Lock Screen, for 15 minutes after a session ends by itself): `RestartSessionIntent` tries to turn the microphone back on in place (iOS 18 and later, as an `AudioRecordingIntent`), and opens Verbose straight into the session when iOS refuses.

These work in your builds too. A session lasts until its idle timeout (2 hours unless you choose 10 or 30 minutes, 1 or 4 hours, or Until I end it; the 8-hour Live Activity limit always ends it), and a phone or FaceTime call or Siri pauses it instead of ending it.

## Notes for App Review

Paste this into App Store Connect › App Review Information › Notes, so the reviewer can check guideline 4.4.1 (keyboards must work without full network access and without Full Access):

> The Verbose keyboard types without Full Access: it has a full QWERTY layout with shift, caps lock, numbers, symbols, space, return, delete, and the globe key, and it opens in that layout when Full Access is off. Full Access is needed only for dictation, because the Verbose app passes your words to the keyboard through a shared App Group container. Without it, the keyboard's Dictate key explains this and shows where to turn it on (Settings › Verbose › Keyboards › Allow Full Access). The keyboard makes no network requests.

What changes without Full Access, in code:

- `KeyboardModel.defaults` returns nil, so nothing reads or writes the App Group. Snippets, Recent (insert your last transcript), the session, and the format chip are hidden.
- The keyboard opens in typing (`KeyboardSurface.initial`). With Full Access it opens in the view you used last, dictation the first time.
- Key presses play the system input click. Haptics play only with Full Access.

## App privacy answers

Verbose has no account, no server, and no analytics or crash-reporting SDK. The Swift packages are WhisperKit (Argmax), FluidAudio, Sparkle (Mac direct download only), and YouTubeKit; none of them sends usage data. Use these answers in App Store Connect › App Privacy:

- **Do you or your third-party partners collect data from this app?** No. The label reads **Data Not Collected**.
- **Tracking:** none. No advertising identifier, no fingerprinting, and no data shared with data brokers.

Why each network use isn't collection. Settings › Privacy lists every one by host, and Local Only refuses all of them:

| What | Where it goes | Why it isn't collected |
|---|---|---|
| Model downloads | huggingface.co (Parakeet, Whisper, speaker and speech-detection models); Apple (speech assets, through the system) | A download. Nothing about you or your recordings is sent. |
| Link downloads | The site you paste (YouTube, Vimeo, Dropbox, and others) and its thumbnail host | You asked for that page's audio. Nothing is sent to the developer. |
| Cloud cleanup (opt-in, off by default) | api.anthropic.com or api.openai.com, with your own API key | Your words go to your own account with that provider, at your request. The developer never receives them and has no agreement with the provider about your data. |
| Update checks (Mac direct download only) | raw.githubusercontent.com (the appcast) | Sparkle sends the app version; system profiling is off. Not part of App Store builds. |
| iCloud sync | Your own iCloud container | Apple's service. The developer can't read it. |

If App Review asks about cloud cleanup, the conservative alternative is to declare **User Content › Other User Content**: not linked to the user, not used for tracking, purpose App Functionality. Tim decides; the default answer is accurate because the data goes only to the person's own provider account.
