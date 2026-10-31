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

The TestFlight job in `.github/workflows/build-swift.yml` (main builds only) runs two tracks, one after the other:

| Track | Build number | YouTube on the iPhone | Who gets it |
|---|---|---|---|
| internal | N (the run number) | Yes: `VERBATIM_PHONE_CONDITIONS_YES="APP_STORE YOUTUBE_ON_DEVICE"` | Your App Store Connect team. Apple doesn't review these builds. |
| public | N.1 | No: `VERBATIM_PHONE_CONDITIONS_YES="APP_STORE"`. YouTube links go to the Mac (`LinkFetchError.needsMac`) | Anyone with the public link, after Beta App Review |

- Don't add an internal build to an external testing group or submit it for App Review. Guideline 5.2.3 makes YouTube downloads a rejection risk.
- Internal goes first so build numbers rise in upload order: N, N.1, N+1, N+1.1. Both carry build N's release notes; the apps read N.1 as N (`ReleaseNotes.buildNumber`).
- To submit to the App Store, archive the **VerbatimPhone App Store** scheme as described above, without the override, and upload that build.

### Public TestFlight link

The public track's last step, "Share the public build through the TestFlight link," runs `ReleaseNotes/testflight_share.py share` with the same App Store Connect key as the upload. It:

1. Waits until App Store Connect has processed build N.1.
2. Finds the external group **Friends**, or makes it with its public link on, and prints the link as a notice on the run.
3. Fills in the beta description and the feedback address (hello@stumpandroot.co) when they're empty.
4. Adds the build to the group and submits it for Beta App Review.

Apple reviews one build per version at a time. When another build is still in review, the step adds this one to the group without submitting it and says so in a notice. Submit it in App Store Connect once that review ends, or let the next build submit itself.

Before the first submission, fill in the review contact's name, phone, and email in App Store Connect › TestFlight › Test Information. Only you can fill in the phone. Until then, the step adds the build to the group, skips the submission, and warns with the missing fields.

Testers can install a build only after Beta App Review approves it. The first review takes the longest; Apple may approve later builds of the same version without a full review. The step never fails the build.

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
| YouTube audio on the iPhone (`YOUTUBE_ON_DEVICE`, YouTubeKit in `PhoneLinkFetcher`) | On | Not defined. YouTube links go to the Mac's Queue, like any site the iPhone can't fetch. The public TestFlight track generates the project with `VERBOSE_YOUTUBEKIT=NO`, so YouTubeKit and its JavaScript bundle aren't in the binary; the upload step refuses an archive that contains them. For a local App Store archive, run `VERBOSE_YOUTUBEKIT=NO bash tools/generate-project.sh` first. |
| Vimeo, and a page's `og:video` or `twitter:player:stream`, on the iPhone (`PhoneLinkFetcher`) | On | Compiled out (guideline 5.2.3). Vimeo links go to the Mac's Queue. The iPhone fetches direct audio and video file links, podcast feeds and Apple Podcasts episodes, Dropbox, Google Drive, OneDrive, and iCloud Drive share links, and a page's `og:audio`. |
| What's new | Every build's notes | From build 255 on, without items about TestFlight, YouTube, TikTok, or the beta, and with versions named without "beta" (`ReleaseNotes.forStore`). |
| Version label | "1.0 beta (N)" | "1.0 (N)": the AppStore configuration sets `VERBOSE_CHANNEL` to empty (guideline 2.2). |
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

## In-app purchase

Verbose is free to download on iPhone. A free 7-day trial of everything starts when the person taps "Try it free for 7 days," and one in-app purchase, **Verbose Unlock**, unlocks everything for good. There's no subscription and nothing renews. The design is in `DESIGN.md` §21; the code is `Verbatim/Model/Entitlement.swift` (the rules, checked by `tools/test-entitlement.sh`), `VerbatimPhone/Unlock.swift` (StoreKit 2), and `VerbatimPhone/UnlockViews.swift` (the screens).

### Create the products in App Store Connect

In App Store Connect › Verbose › Monetization › In-App Purchases, create two **non-consumable** in-app purchases:

| Reference name | Product ID | Price | Display name | Description |
|---|---|---|---|---|
| 7-day free trial | `co.stumpandroot.verbatim.ios.trial7` | Free (tier 0, $0.00) | 7-day free trial | Everything in Verbose Unlock for 7 days. It's free, and it doesn't renew. |
| Verbose Unlock | `co.stumpandroot.verbatim.ios.unlock` | $14.99 (US) | Verbose Unlock | Recordings of any length, imports, app audio, templates, and every export. One purchase. |

For each one:

1. Leave **Family Sharing** off. It can be turned on later but never off again.
1. Add an **App Review screenshot**: the unlock sheet (the self-test's `p15a-unlock-sheet.png`, from CI's `ci-screens-phone` artifact, or a screenshot from a device). App Review needs one per product; the same sheet works for both.
1. Add review notes: "Starts the 7-day free trial; Verbose counts 7 days from this purchase's date" for the trial, and "Unlocks every feature for good" for Verbose Unlock.
1. Submit both products with the app version that adds them (App Store Connect asks on the version page, under In-App Purchases and Subscriptions). Products created after the first version ships go with the next version.

The product IDs are fixed in code (`UnlockProduct`). Changing one means changing the code and the StoreKit configuration file too.

### How it works

- **The trial** is a purchase of the free product, so Apple's purchase sheet shows $0.00. Verbose counts 7 days from that transaction's `purchaseDate` (`Transaction.all` and `Transaction.currentEntitlements`), so the trial follows the Apple Account: reinstalling, restoring, or a second purchase never restarts it.
- **The entitlement comes only from StoreKit on this iPhone,** at launch and from `Transaction.updates` (a refund, Ask to Buy, a purchase on another iPhone). A refunded or revoked purchase reverts. The last state is cached so a launch without a network shows it at once, then StoreKit is asked again. A Mac license never unlocks the iPhone, and nothing unlocks from iCloud sync.
- **Free:** Dictate, the keyboard and keyboard sessions, recordings up to 10 minutes each, Apple Watch recordings (imported whole: the iPhone can't stop a recording on the watch, and audio is never cut), transcripts, speakers, search, Thoughts, Journal, Plan my day (Brain dump's automatic run and Send to Reminders too), iCloud sync, copy and share as text, and Export everything.
- **Verbose Unlock (or the trial):** recordings of any length, Import (files, Photos, links, and what's shared in), App audio and Live captions, templates other than Plan my day, Ask, Recipes, Cloud cleanup, and every export format beyond plain text, with Share original audio.

### Test it

- **In Xcode:** the VerbatimPhone scheme runs with `VerbatimPhone/Verbose.storekit` (`storeKitConfiguration` in `project.yml`), so purchases work without App Store Connect. Use Debug › StoreKit › Manage Transactions to refund, delete, or approve a pending purchase, and to start over (delete both transactions). Editor › Time Rate speeds up time to see the trial end.
- **In TestFlight:** purchases use the sandbox and are free; testers see "[Environment: Sandbox]" on Apple's purchase sheet. The trial and the unlock stay on the tester's account; there's no way to undo a TestFlight purchase, so test the trial's end with a new sandbox account (App Store Connect › Users and Access › Sandbox) or in Xcode.
- **On a device:** check both products load (the sheet shows "Unlock for $14.99"), Try it free, the 9:00 chip and the stop at 10:00 in a free recording, Restore Purchases after deleting and reinstalling the app, and a refund (Xcode's transaction manager) reverting to the free version.
- **Self-test:** CI's simulator tour starts unlocked with a stand-in store (`StubPurchases`) and ends with the unlock's own tour, screenshots `p15a-unlock-sheet` to `p15k-unlock-onboarding-offer`, and `UITEST PASS|FAIL unlock:` lines.

### What it satisfies

- **3.1.1, free trials for non-subscription apps:** the trial is a non-consumable at $0 named "7-day free trial" (the "XX-day Trial" naming the guideline asks for). Before it starts, the sheet states its length, that it charges nothing and doesn't renew, and what locks after it ("After 7 days, the features above lock again and Verbose goes back to the free version unless you unlock it"), under the list of what it adds. The welcome tour's offer says the same.
- **3.1.1, unlocking features in the app:** in-app purchase only. **Restore Purchases** is on the sheet and in Settings › Account and plan.
- **3.1.1 and 3.1.3, no other ways to pay:** nothing on iPhone links to or mentions the website's prices, Polar, buying outside the App Store, or Mac licenses. The sheet links only Apple's sheet, the Terms of use, and the Privacy policy (`Links.terms`, `Links.privacy`).
- **3.1.2:** not a subscription, so none of the subscription rules apply.
- **Nothing made gets locked** (5.1.1 spirit): transcripts, results, and synced items stay readable and shareable as text after the trial; audio is never discarded; shared files wait in the inbox until the unlock.

## Notes for App Review

Paste this into App Store Connect › App Review Information › Notes (guideline 2.3.1(a)):

> **No account is needed.** Verbose records and transcribes on this iPhone; nothing is uploaded to us. Transcription models download once from Hugging Face the first time you record.
>
> **In-app purchase.** Verbose is free. "7-day free trial" is a free non-consumable that starts a trial of everything (guideline 3.1.1); "Verbose Unlock" is a non-consumable that unlocks everything for good. Tap any locked feature (Import, Live captions, a template other than Plan my day) or Settings › Verbose Unlock to see the sheet; Restore Purchases is on it and in Settings › Account and plan.
>
> **Background audio.** Verbose uses the audio background mode for two things: a recording keeps going with the screen locked, and a dictation session from the Verbose keyboard keeps the microphone ready so you can dictate into other apps. While a session is on, iOS shows the orange microphone indicator and Verbose shows a Live Activity with an End button. The session ends after its idle timeout (Settings › Keyboard), or when you tap End.
>
> **Background fetch.** Scheduled questions you save in Ask (Recipes) run on the device with Apple Intelligence. Nothing is sent anywhere.
>
> **Broadcast extension.** Transcribe what's playing uses a ReplayKit broadcast extension to capture another app's audio only, never the screen or the microphone. iOS shows its own Start Broadcast sheet each time.
>
> **Apple Watch.** The watch app records audio and sends it to the iPhone, which transcribes it.
>
> **Cloud cleanup** (Settings › Dictation and keyboard) is optional and off by default. It needs your own Anthropic or OpenAI API key, and Verbose asks for permission before any text is sent. Without a key, cleanup runs on the device.
>
> **The Mac app is optional.** Verbose works fully on its own. With the Mac app on the same iCloud account, some sites the iPhone can't download (YouTube, Vimeo) go to the Mac to transcribe; without a Mac, Verbose says the site isn't supported here.
>
> **The keyboard (guideline 4.4.1).** The Verbose keyboard types without Full Access: it has a full QWERTY layout with shift, caps lock, numbers, symbols, space, return, delete, and the globe key, and it opens in that layout when Full Access is off. Full Access is needed only for dictation, because the Verbose app passes your words to the keyboard through a shared App Group container. Without it, the keyboard's Dictate key explains this and shows where to turn it on (Settings › Verbose › Keyboards › Allow Full Access). The keyboard makes no network requests. To start dictating, the keyboard opens Verbose for a moment to turn on the microphone, because iOS doesn't let a keyboard use the microphone itself.

What changes without Full Access, in code:

- `KeyboardModel.defaults` returns nil, so nothing reads or writes the App Group. Snippets, Recent (insert your last transcript), the session, and the format chip are hidden.
- The keyboard opens in typing (`KeyboardSurface.opening`). With Full Access it opens in the view you used last, dictation the first time.
- Key presses play the system input click. Haptics play only with Full Access.

## App privacy answers

Verbose has no account, no server, and no analytics or crash-reporting SDK. The Swift packages are WhisperKit (Argmax), FluidAudio, Sparkle (Mac direct download only), and YouTubeKit; none of them sends usage data. Use these answers in App Store Connect › App Privacy:

- **Do you or your third-party partners collect data from this app?** No. The label reads **Data Not Collected**.
- **Tracking:** none. No advertising identifier, no fingerprinting, and no data shared with data brokers.

Why each network use isn't collection. Settings › Privacy lists every one by host, and Local Only refuses all of them:

| What | Where it goes | Why it isn't collected |
|---|---|---|
| Model downloads | huggingface.co (Parakeet, Whisper, speaker and speech-detection models); Apple (speech assets, through the system) | A download. Nothing about you or your recordings is sent. |
| Link downloads | The address you paste (a podcast, an audio or video file, a Dropbox or other cloud share link; YouTube and Vimeo only on the Mac) and its thumbnail host | You asked for that page's audio. Nothing is sent to the developer. |
| Cloud cleanup (opt-in, off by default, asks first) | api.anthropic.com or api.openai.com, with your own API key | Your words go to your own account with that provider, at your request, after an alert that names the provider and what's sent (guideline 5.1.2(i)). The developer never receives them and has no agreement with the provider about your data. |
| Update checks (Mac direct download only) | raw.githubusercontent.com (the appcast) | Sparkle sends the app version; system profiling is off. Not part of App Store builds. |
| iCloud sync | Your own iCloud container | Apple's service. The developer can't read it. |

If App Review asks about cloud cleanup, the conservative alternative is to declare **User Content › Other User Content**: not linked to the user, not used for tracking, purpose App Functionality. Tim decides; the default answer is accurate because the data goes only to the person's own provider account.
