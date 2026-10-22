# App Store builds

One build setting, `VERBATIM_APP_STORE`, decides whether an iPhone build uses features that App Review may reject. Your own builds (Debug, Release, CI, `build.sh`) keep it `NO` and keep every feature. App Store and TestFlight builds set it to `YES`.

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

Quick check (`.github/workflows/check-swift.yml`) compiles the iPhone app both ways on every push. The App Store pass confirms that `APP_STORE` is defined, that `YOUTUBE_ON_DEVICE` isn't, and that none of the undocumented selector or class names below are left in the app.

## What the flag changes

`VERBATIM_APP_STORE=YES` defines the `APP_STORE` compilation condition in the app, the keyboard, and the widget extension (`project.yml` picks it with `$(VERBATIM_*_CONDITIONS_$(VERBATIM_APP_STORE))`). Code under `#if APP_STORE` is compiled out, not only switched off at run time. `Distribution.abilities(appStore:)` in `VerbatimKeyboard/KeyboardFormat.swift` describes the result.

| Feature | Your builds | App Store builds |
|---|---|---|
| Keyboard reads the host app's bundle ID (`_hostBundleID`, `_hostApplicationBundleIdentifier` in `KeyboardViewController.hostBundleID()`) | On | Compiled out; returns nil. The format chip's Auto infers from the text field instead. |
| Keyboard opens Verbatim to start a session (`openURL:options:completionHandler:` through the responder chain in `KeyboardViewController.openContainingApp`) | On | Compiled out; returns false. The keyboard shows "Start a session to dictate" with the ways to start one. |
| App switches back to the app you came from (`_systemNavigationAction` breadcrumb and `LSApplicationWorkspace.openApplicationWithBundleID:` in `KeyboardSession.returnToHostApp`) | On | Compiled out; returns "not available in App Store builds". The start screen tells you how to go back. |
| YouTube audio on the iPhone (`YOUTUBE_ON_DEVICE`, YouTubeKit in `PhoneLinkFetcher`) | On | Not defined. YouTube links go to the Mac's Queue, like any site the iPhone can't fetch. YouTubeKit stays linked, but nothing calls it; remove the package dependency in `project.yml` to drop it from the binary. |
| Settings › Keyboard › Start dictating when you come back | Shown | Hidden, because the keyboard can't open Verbatim. |

## Starting a session in App Store builds

The keyboard can't open Verbatim, and iOS doesn't let an app start recording from the background, so each of these opens Verbatim for a moment, turns on the microphone, and then shows "Your session is on" with how to go back to your app:

- **Control Center** (iOS 18 and later): the Start dictation session control (`StartSessionControl`).
- **Action button and Shortcuts:** the Start dictation session App Shortcut (`StartKeyboardSessionIntent`, `VerbatimAppShortcuts`).
- **Lock Screen:** the Verbatim widget, which opens `verbatim://session?start=1&from=widget`.
- **Verbatim:** Settings › Keyboard › Start keyboard session.

These work in your builds too.

## App privacy answers

Verbatim has no account, no server, and no analytics or crash-reporting SDK. The Swift packages are WhisperKit (Argmax), FluidAudio, Sparkle (Mac direct download only), and YouTubeKit; none of them sends usage data. Use these answers in App Store Connect › App Privacy:

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
