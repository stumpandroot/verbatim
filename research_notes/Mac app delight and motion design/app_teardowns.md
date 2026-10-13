# Mac app delight and motion design: app teardowns

Scope note for the report writer: several primary sources were blocked by a fetch-permission timeout in this session and could not be read directly: rauno.me/craft/interaction-design, every.to (the same essay), lookaway.app, blakecrosley.com/guides/design/things, and the Apple HIG Motion page (JavaScript-only render). Findings below come only from pages that were read. Where a source is a third-party "design guide" with the author's own illustrative values, that is flagged, because those numbers are not verified against the shipping app.

## Key question 1: Which specific micro-interactions do these apps use, and how do their designers describe them?

### Takeaway
The apps that balance "alive" with "Apple-native" put almost all of their motion into three places: the primary action (Things' Magic Plus, Not Boring's checkbox, Wispr Flow's dictation pill), transitions between a list and a focused item (Things' task "pop out," Craft's card-to-page expansion), and feedback that confirms a result (Raycast HUDs, toasts, confetti). Keyboard-driven or repeated actions are deliberately not animated (Emil Kowalski's rule, Raycast's practice), and standard controls stay off-the-shelf even in the most maximalist app (Not Boring).

### Cited Findings

**Things 3 (Cultured Code)**
- The Magic Plus button sits by default in "the lower right corner" and "can be dragged and dropped into different spaces of the app to do different things": dropping on the Today list creates a task in that spot, on the Inbox icon creates an Inbox task, and on a day in Upcoming "assigned its start date." — [MacStories review of Things 3](https://www.macstories.net/reviews/things-3-beauty-and-delight-in-a-task-manager/)
- Tapping a task makes it "pop out into a card-like form while the rest of the list fades into the background." Long-pressing lifts the task out of the list for dragging (reorder or reschedule only). — [MacStories](https://www.macstories.net/reviews/things-3-beauty-and-delight-in-a-task-manager/)
- Swiping left selects a task; selection circles appear and swiping across them selects or deselects groups. — [MacStories](https://www.macstories.net/reviews/things-3-beauty-and-delight-in-a-task-manager/)
- Haptics are reserved for specific actions: dragging tasks, using the Magic Plus Button, and pull-down-to-search. "Certain actions are well-suited for the added kickback of the Taptic Engine." — [MacStories](https://www.macstories.net/reviews/things-3-beauty-and-delight-in-a-task-manager/)
- Sidebar hierarchy is typographic: "areas are represented by bold text, while projects are listed below their accompanying areas in a lighter font." Projects show a visual completion indicator. — [MacStories](https://www.macstories.net/reviews/things-3-beauty-and-delight-in-a-task-manager/)
- Overall look: "bold fonts, lovely icons, and thoughtful splashes of color," with the app "dominated by white space." Calendar events render in each calendar's assigned color and "turn grey in Today once they've passed." — [MacStories](https://www.macstories.net/reviews/things-3-beauty-and-delight-in-a-task-manager/)
- The reviewer calls the Magic Plus Button "a welcome element of delight" and says the app is "full of little delights." — [MacStories](https://www.macstories.net/reviews/things-3-beauty-and-delight-in-a-task-manager/)

**Raycast**
- Raycast's stated principles are "fast, simple, and delightful," pursued in "every corner of our products." — [Raycast blog, "A fresh look and feel," Thomas Paul Mann, July 19, 2022](https://raycast.com/blog/a-fresh-look-and-feel)
- Layout decisions from the 2022 redesign: a larger search bar "to reflect its central role and separate it from the results below"; larger leading icons in results "so users can scan results faster"; a bottom action bar that combines actions, toasts, and navigation titles, with toasts "inside the app window" and a dedicated shortcut to expand them. The reason: the ⌘K actions menu was "hidden behind a small button" and easy for new users to miss. — [Raycast blog](https://raycast.com/blog/a-fresh-look-and-feel)
- Icon system: outline style with a bolder stroke, all icons sharing the same stroke-width and corner-radius rules, which designer James McDonald says makes the set "timeless for future updates." Optional Compact Mode strips the UI down to "typing a query and pressing Enter." App icon is a keycap (chosen over glass cubes and magnifiers) modeled on Apple's Magic Keyboard. — [Raycast blog](https://raycast.com/blog/a-fresh-look-and-feel)
- Emil Kowalski cites Raycast as having "no animations" and says it "feels right"; he describes a 500ms enter animation as frustrating in that context, and states the rule "never animate keyboard initiated actions" because users repeat them many times a day. — [Emil Kowalski, "Great Animations"](https://emilkowal.ski/ui/great-animations)
- Third-party design guide (author's illustrations, not Raycast source): window uses vibrancy (`.ultraThinMaterial`) with a 12pt continuous corner radius; shortcut badges use `.caption` text at tertiary color on a 20%-opacity secondary fill with 4pt radius; HUD confirmations "fade and scale out after about 1.5 seconds"; confetti uses a spring and "appears only for earned achievements"; empty state is a "[?]" icon, "No results for 'asdfgh'", a suggestion line, and a "Browse Extensions" button; loading shows cached UI immediately, then a scaled-down `ProgressView`, with skeletons for heavy operations. The page's stated principle: "Delight shouldn't delay." — [Blake Crosley, Raycast design guide](https://blakecrosley.com/guides/design/raycast) (unverified third-party values)

**Craft**
- Craft's interface "stays minimal until you need it." Hovering a sidebar document reveals a `+` icon to create a sub-page; pages drag to reorder; the `/` slash menu offers headers, lists, code, images, dividers; images paste or drag inline. — [Hack Design, Craft toolkit page](https://www.hackdesign.org/toolkit/craft/)
- Third-party design guide (author's sketch values, unverified): page open uses a spring (response 0.35, damping 0.85) with matched-geometry expansion from the card plus scale and opacity; block insert/remove uses a top/bottom move with opacity, spring (response 0.3, damping 0.8); five layout styles for the same data (list, medium card 3-col, large card 2-col, gallery 4-col, board); each page can set its own background (solid, gradient, image, or paper texture) and accent. — [Blake Crosley, Craft design guide](https://blakecrosley.com/guides/design/craft)

**(Not Boring) Habits, Andy Allen / Andy Works**
- The checkbox is "an interactive event replete with explosive 3D animations, custom sounds, and playful haptics." Allen: "We went all out. There was a lot of room to wrap something special around that box." — [Apple Developer, "Behind the Design: (Not Boring) Habits," Aug 29, 2022](https://developer.apple.com/news/?id=9ab1g4r3)
- The checkbox must be pressed and held longer than expected: "It's a very big, gross interaction... we found we had to make it much more intentional; we needed feedback that told you you needed to keep holding." — [Apple Developer](https://developer.apple.com/news/?id=9ab1g4r3)
- "There were thousands of iterations." Allen's process: "I'd do something and think, 'OK, this is way over the top and I'm gonna do it anyway.' And then I put it in and it's like, 'You know, it's not that bad!'" He layered "maybe six or seven things in the checkbox, but most games probably have two or three times that for any one interaction." — [Apple Developer](https://developer.apple.com/news/?id=9ab1g4r3)
- Standard controls stay standard: "Most of [our] standard controls are fairly off-the-shelf, which makes things very simple and predictable... We didn't have to rethink how a button or a popover works." 3D is authored in Blender, rendered with SceneKit, composed with UIKit and SwiftUI. — [Apple Developer](https://developer.apple.com/news/?id=9ab1g4r3)
- Not Boring Weather (iOS): holding a thumb on the temperature rotates it like an object; tapping clouds rearranges them, with cloud count matched to real cloudiness; rain blows in the correct direction using the compass; numbers and images make chime-like tones when touched, "for no reason other than your own enjoyment." On the rain direction: "We don't expect people will notice this." — [Brand Knew / Fast Company reprint](https://www.brandknewmag.com/?p=20392)

**Wispr Flow (Mac)**
- While the hotkey is held, a small floating bar appears at bottom-center; an optional always-on idle bubble can stay on screen. Listening state: the bar expands and shows white vertical bars that rise and fall with input volume. Processing: bars stop when the hotkey releases; "There is no separate spinner or 'thinking' state." The pasted text is the success signal. A start chime plays when recording begins. Audio is kept only if speech lasted about 0.5 seconds or longer. — [Wispr Flow UX reference (agent-native corpus; secondary compilation of docs and reviews)](https://cdn.jsdelivr.net/npm/@agent-native/core@0.124.6/corpus/templates/clips/desktop/design-refs/wispr-ux.md)

**General interaction-design principles from designer write-ups**
- Emil Kowalski: use `ease-out` for snappy responses; "Your animations should also usually be shorter than 300ms"; animate only `transform` and `opacity` for 60fps; make animations interruptible ("A CSS transition can be interrupted and smoothly transition to a new value"); respect `prefers-reduced-motion` (his example swaps a 0.2s bounce for a 0.2s fade); match easing and duration to product character (Sonner is deliberately slower and uses `ease` rather than `ease-out` "to feel more elegant"). Family's iOS app is cited as the snappy reference; Family's drawer as a cohesive example. — [Emil Kowalski, "Great Animations"](https://emilkowal.ski/ui/great-animations)
- Rauno Freiberg (via Tommy Geoco's write-up): prototype in code because "code is the material"; validate by pushing to extremes ("Validation is filtering"); Disney's Follow-Through and Overlapping Action applied to UI means inner elements (icons, labels) should appear "100–200ms after the main transition" when a button morphs into a text field or a modal opens; unreliable polish is "lipstick on a pig," and an animated text cursor that glitches during fast typing is the cautionary example. — [UX Tools, "Your UI needs more Walt Disney"](https://www.uxtools.co/blog/your-ui-needs-more-walt-disney)
- Rauno Freiberg on "fidgetability": "Wonderful interactions don't have to be entirely practical" and "fidgeting does feel like a part of intentional interaction design" (he notes "there is no scientific research that supports this claim"). Examples: stretching and releasing the Apple Wallet card stack, the iOS 6 Mail pull-to-refresh droplet, the AirPods case click. — [Design Lobster #149, "Fidgetability"](https://designlobster.substack.com/p/150-fidgetability)
- The "Linear style" visual language: dark base, Inter typeface, gradient accents (Linear's logo is "a gradient purple sphere"), layer blurs and glows, "micro-motion effects," with Raycast cited for "linear light effects" against a dark background. — [UX Collective Bootcamp, "The rise of Linear style design"](https://bootcamp.uxdesign.cc/the-rise-of-linear-style-design-origins-trends-and-techniques-4fd96aab7646)

### Inferences
- The pattern across Things, Raycast, and Wispr Flow is one hero interaction that carries all the personality (Magic Plus, the result list, the dictation pill), with everything else left to system defaults. Allen's "we didn't have to rethink how a button or a popover works" is the same principle stated by the most maximalist designer in the set.
- Raycast's lack of motion is itself a design choice tied to keyboard frequency, so "alive" on Mac is less about animation count and more about responsiveness and confirmation (HUD, toast, action bar).
- The third-party guide values for Craft (spring response 0.3–0.35, damping 0.8–0.85) are plausible SwiftUI defaults but should be presented as illustrative, not measured.

### Gaps
- Rauno Freiberg's "Invisible Details of Interaction Design" could not be fetched (rauno.me and every.to both blocked). Specific details such as hover intent delays, diagonal-menu safe triangles, and optimistic-UI examples therefore have no citation here.
- No primary Linear design-blog post, Craft blog or changelog post, Arc/Browser Company design post, or Family design post was retrievable in this session. Linear and Arc micro-interaction details are undocumented in these notes.
- Superwhisper, MacWhisper, and Granola: no design-focused source was found; search results were feature/pricing comparisons only.
- Things 3's checkbox animation and macOS-specific hover states are not described in the MacStories review.

## Key question 2: How do these apps handle empty states, first launch, and processing/progress states with character but without noise?

### Takeaway
Documented examples favor zero-friction starts (no sign-in, cached UI first), progress that is embedded in the object rather than a separate spinner (Things' project completion indicator, Wispr Flow's live bars that stop on release), and confirmations that dismiss themselves.

### Cited Findings
- Bears Gratitude (ADA 2024 Delight and Fun winner): "There is no sign-in screen, so users can start writing right away." Prompts are written in the user's voice. — [The Note, "The good news bears"](https://thenote.app/post/en/the-good-news-bears-inside-the-adorably-unorthodox-design-of-bears-gratitude-k89vshmfmf)
- Wispr Flow onboarding sequence: browser sign-in returns to the app; native macOS prompts for Microphone and Accessibility; mic test using the same white-bars meter as the live pill; hotkey setup (default Fn); profile/privacy/language; a "Try It Yourself" sandbox with simulated Gmail and Notion fields; a Transform before/after demo; then land on Flow Hub. Processing has no spinner; the paste is the confirmation. — [Wispr Flow UX reference](https://cdn.jsdelivr.net/npm/@agent-native/core@0.124.6/corpus/templates/clips/desktop/design-refs/wispr-ux.md)
- Raycast (third-party guide, unverified): empty state = icon, "No results for '<query>'", one suggestion line, one button; loading = show cached results immediately, scaled-down `ProgressView`, skeletons for heavy work, "Never block the main thread"; HUD confirmations auto-dismiss after ~1.5s. — [Blake Crosley, Raycast guide](https://blakecrosley.com/guides/design/raycast)
- Raycast (primary): toasts live inside the window in the action bar with a shortcut to expand details, replacing a hidden menu. — [Raycast blog](https://raycast.com/blog/a-fresh-look-and-feel)
- Things 3: projects in the sidebar carry a completion indicator; the Watch complication shows "a progress ring around the border" reflecting the Today list. — [MacStories](https://www.macstories.net/reviews/things-3-beauty-and-delight-in-a-task-manager/)
- Not Boring Habits frames progress as "a video game with 66 levels" (66 days to form a habit), with named milestones like "Karat," "Summit" (a shining gold mountain), and a "final battle." — [Apple Developer](https://developer.apple.com/news/?id=9ab1g4r3)
- LookAway (Mac): pre-break reminders are an "unobtrusive notification" whose screen position is adjustable; the skip button can be hidden; an audio signal marks the end of a break; 1.10 added posture and blink "Wellness Reminders" delivered "through subtle animations" and customizable menu bar icons. — [ifun.de](https://www.ifun.de/lookaway-mac-app-setzt-bildschirmpausen-durch-232437); [AlternativeTo news](https://alternativeto.net/news/2025/2/lookaway-1-10-update-is-out-with-wellness-reminders-deep-focus-features-and-more)
- Emil Kowalski: add animation only where it adds information or marks a state change (App Store cards, modal enter/exit); Vercel's v0 explainer animation is cited as useful because it is "both entertaining and informative." — [Emil Kowalski](https://emilkowal.ski/ui/great-animations)
- Apple HIG Motion meta description (only text retrievable): "Beautiful, fluid motions bring the interface to life, conveying status, providing feedback and instruction, and enriching the visual experience of your app or game." — [Apple HIG, Motion](https://developer.apple.com/design/human-interface-guidelines/motion)

### Inferences
- "Processing with character" in the Mac apps surveyed means the live indicator and the result are the same object (Wispr's bars stop, text appears), rather than a separate branded loader. A transcription app can follow the same model: waveform while recording, waveform freezes, transcript fills in.
- Onboarding in Wispr Flow spends its personality budget on a practice sandbox, not on illustrations or mascots.

### Gaps
- No documented empty-state designs for Things 3 (Mac), Craft, Linear, Arc, or Granola were found.
- The full HIG Motion best-practice text could not be read (page requires JavaScript); the standard guidance on brief, purposeful motion and Reduce Motion is not quoted here.
- LookAway's break overlay visuals and whether it uses a character are unconfirmed; lookaway.app was blocked.

## Key question 3: How do apps with mascots or illustrated characters deploy them: where, how often, how animated?

### Takeaway
The best-documented mascot systems (Duolingo, Bears Gratitude) place characters at task moments and tie animation to user state (correct/incorrect, idle, inactivity), and both studios describe the art as the product's anchor rather than decoration. On Mac specifically, no surveyed app documents a mascot system; Not Boring's "character" is the 3D object itself.

### Cited Findings
- Duolingo characters are built in Rive, chosen "for compact file sizes, a clean fit with the app's architecture, and a smooth handoff from animator to engineer." The State Machine is "a visual representation of the logic that connects the animations." — [Duolingo blog, "World character visemes," Nov 10, 2022](https://blog.duolingo.com/world-character-visemes)
- Each character has 20+ mouth shapes; body poses and mouth states run as separate, simultaneous states. Characters appear during lessons and challenges, speak in sync with audio, stop speaking if the user finishes early, and move to a final reacting state for correct or incorrect answers. Idle behaviors are "head nods, blinking, and eyebrow movement." Tapping a word makes the character say and animate that word. — [Duolingo blog](https://blog.duolingo.com/world-character-visemes)
- Duo's app icon changes expression when the app has not been opened for a long time, reinforced by push notifications. — [Diseñando Apps newsletter](https://disenandoapps.substack.com/p/27-detalles-invisibles)
- Apple on Duolingo (ADA 2023 Delight and Fun winner): "Quests, challenges, and leaderboards help gamify an already fantastic experience." — [Apple Design Awards 2023](https://developer.apple.com/design/awards/2023/)
- Bears Gratitude uses hand-drawn bear mascots by illustrator Nayomi Hettiarachchi; the creators say "The art is the heart of the app" and the bears serve as the design anchor. — [The Note](https://thenote.app/post/en/the-good-news-bears-inside-the-adorably-unorthodox-design-of-bears-gratitude-k89vshmfmf)
- Apple on ADA 2025 finalist Vocabulary: "charming, consistent illustrations" and "the use of haptics is a nice touch." ADA 2025 Delight and Fun winner CapWords: "each flash card transition is accompanied by a real-world sound." — [Apple Design Awards 2025](https://developer.apple.com/design/awards/2025/)
- Not Boring apps use unlockable skins (easter eggs) that change interface color and texture, with planned seasonal skins from commissioned artists; pricing was $15/year or $70/year including limited-edition skins. — [Brand Knew](https://www.brandknewmag.com/?p=20392)
- Headspace won ADA 2023 Social Impact; Apple's description focuses on Apple Watch integration, not illustration. — [Apple Design Awards 2023](https://developer.apple.com/design/awards/2023/)

### Inferences
- The transferable rule from Duolingo is "state-driven, not time-driven": the character animates in response to what the user did or has not done (inactive icon, correct/incorrect), with only subtle idle motion in between. That keeps a character from reading as a toy.
- For a Mac utility, the Not Boring and Wispr examples suggest the "character" can be the hero object (checkbox, pill, waveform) with sound and motion, rather than a drawn creature.

### Gaps
- No source documents frequency rules (how often a mascot should appear per session) for any app.
- Headspace's illustration system and Craft's illustrations were not covered by any retrievable source.
- LookAway: unknown whether it uses a character at all.

## Key question 4: What are the common critiques (what readers call "too much" or "toy-like"), and where is the boundary?

### Takeaway
Critiques cluster around three failure modes: motion attached to high-frequency actions (Kowalski's 500ms example), polish that breaks under stress (Freiberg's "lipstick on a pig"), and novelty that hides function (Arc's undiscoverable gestures, Not Boring being "almost overdesigned"). The boundary the sources draw is reliability and purpose, not visual intensity.

### Cited Findings
- Emil Kowalski: a 500ms enter animation in a launcher is frustrating; "never animate keyboard initiated actions"; Framer Motion's `requestAnimationFrame` animations lag when the main thread is busy, and Vercel's dashboard tab animation dropped frames until moved to CSS. — [Emil Kowalski](https://emilkowal.ski/ui/great-animations)
- Rauno Freiberg (via Geoco): an effect "is delightful if it stays dependable under extreme input and clearly improves the feel of the interface. It becomes gimmicky when it looks impressive in a demo but fails in real use." Partial reliability reads as low quality. — [UX Tools](https://www.uxtools.co/blog/your-ui-needs-more-walt-disney)
- Andy Allen on the tension: "There was some real tension there with my minimalist graphic design background," and "minimalism is a fun place to visit for me, but it's not somewhere I want to live... I don't want to live in a perfectly white-walled museum all the time." He concedes the audience is narrow: "[Not Boring] apps aren't for everyone... But they're definitely really for some people," and "It's never going to be a majority of people. We kind of like that." — [Apple Developer](https://developer.apple.com/news/?id=9ab1g4r3); [Brand Knew](https://www.brandknewmag.com/?p=20392)
- Allen's own framing of the risk: Habits "required the nifty zing of its brand, but it also needed to be a lightweight, quick-launching, scannable daily utility app." — [Apple Developer](https://developer.apple.com/news/?id=9ab1g4r3)
- Fast Company's writer called the Not Boring interface "novel and self-celebratory" and "almost overdesigned," while saying it "seems to be having fun as it conveys information." Allen wants apps "almost overdesigned to be unique statements unto themselves." — [Brand Knew](https://www.brandknewmag.com/?p=20392)
- Arc critique (Pratt IXD): bookmarking by dragging a page to the top has "no way of gaining this knowledge through the current design"; the Library icon's "lack of signifiers does very little to help the user figure functionality out"; the "+" button unexpectedly reveals "New Boost" with "no visible way to go back from this slip"; "new icons show up on random hover" is listed as a problem. Positives: "constant tool-tips and instructions," clear URL-bar signifiers (link and camera icons appear on cursor approach). — [Pratt Institute IXD, "Design Critique: Arc Browser"](https://ixd.prattsi.org/2023/02/design-critique-arc-browser/)
- Design Lobster notes fidget-spinner-style delight carries weak evidence for its claimed benefits and can become a distraction (classroom analogy). — [Design Lobster](https://designlobster.substack.com/p/150-fidgetability)
- The "Linear style" became so common that people joked about renaming "dark mode" as "linear style." — [UX Collective Bootcamp](https://bootcamp.uxdesign.cc/the-rise-of-linear-style-design-origins-trends-and-techniques-4fd96aab7646)
- Apple's ADA language rewards restraint in games too: for Endling, "The game's simple controls ensure that you focus on the powerful storyline rather than the interactions." — [Apple Design Awards 2023](https://developer.apple.com/design/awards/2023/)

### Inferences
- A workable boundary statement: animate objects, not commands. Objects (a card, a task, a pill) can move with spring physics and sound; commands (keyboard shortcuts, repeated list navigation) should respond instantly. Every surveyed designer either states this or practices it.
- "Toy-like" critiques attach to apps where novelty replaces affordance (Arc's hidden gestures, random hover icons), not to apps with a lot of motion per se. Not Boring survives its maximalism because the standard controls are standard.
- The Linear-style critique is about sameness, not excess: dark gradient glows now read as a template, so a Mac app that wants to feel native and distinct should not lean on that palette.

### Gaps
- No MacStories, Setapp, or 9to5Mac review was found that explicitly labels a 2023–2026 Mac app "too animated" or "toy-like"; the critiques above are from designer essays and an academic critique of Arc.
- Reader-level critiques of Craft, Things, Raycast, or Lookaway motion were not found.

## Reference: Apple Design Award Mac-eligible apps 2023–2025

### Takeaway
Few ADA app winners run on Mac; the Mac-capable app winners are Universe (2023), Flighty (2023), SwingVision (2023), Play (2025), and finalists iA Writer and Mela (2025). Apple's citations emphasize cross-device continuity, system integration, and accessibility more than animation.

### Cited Findings
- 2023 Mac-capable app winners: Universe — Website Builder (Inclusivity; "a fantastic implementation of Dynamic Type and VoiceOver"), Flighty (Interaction; "a look that mirrors time-honored airport design conventions," "incredible Live Activities and Dynamic Island integration"), SwingVision (Innovation). Game winners on Mac: stitch. and Resident Evil Village. — [Apple Design Awards 2023](https://developer.apple.com/design/awards/2023/)
- 2024 app winners: Bears Gratitude (Delight and Fun), oko (Inclusivity), Procreate Dreams (Innovation), Crouton (Interaction), Gentler Streak (Social Impact), Rooms (Visuals and Graphics), djay pro (Spatial). Platforms not stated on the MacStories page. — [MacStories](https://www.macstories.net/news/apple-design-award-winners-announced/)
- 2025 Mac-capable app entries: Play (Innovation winner; "interactive prototypes using native SwiftUI frameworks, which can then be sent to Xcode"), iA Writer (Interaction finalist; "swiping right to access your library and left to preview a document"), Mela (Interaction finalist; "Timers integrate with the Dynamic Island"). Mac games cited: Balatro, DREDGE, Thank Goodness You're Here!, Neva, Control, Skate City, Prince of Persia, puffies., Land of Livia. ADA 2025 descriptions that name delight mechanics: CapWords ("each flash card transition is accompanied by a real-world sound"), Denim ("smooth scroll transitions and elegant text and mesh gradients," "custom haptics"), PBJ — The Musical ("paper cutouts animated by hand," "cool haptics"), Opal ("haptics when unlocking 'gems'"). — [Apple Design Awards 2025](https://developer.apple.com/design/awards/2025/)

### Inferences
- Apple's own Mac-facing praise is for native framework use (SwiftUI in Play), consistency across iPhone/iPad/Mac, and accessibility. A Mac app aiming for ADA-style "native" credibility should prioritize those over motion volume.

### Gaps
- ADA 2024 platform data and Apple's descriptions were not retrieved (only the winners list).
- ADA 2026 results are not covered by any source read in this session.
