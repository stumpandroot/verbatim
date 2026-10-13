# SwiftUI animation performance on macOS 14–26: cheap vs expensive APIs, when to leave SwiftUI, Tahoe pitfalls, and profiling

Scope note: every claim below carries a source. Apple WWDC transcripts and Apple docs are primary. Apple Developer Forums threads and blog posts are marked anecdotal where they report one developer's observation without Apple confirmation. Several things the brief asked for (direct CPU benchmarks across TimelineView/Canvas vs Core Animation vs Rive vs Lottie; a documented "transactions rebuild the scene/toolbar/menus" regression on macOS 26; a recommended hover rate limit) have no reliable published source that I could find, and are listed under Gaps rather than invented.

## Key question 1: Which SwiftUI animation APIs are cheap vs expensive, and what does Apple actually recommend (WWDC 2023–2025)?

### Takeaway
Apple's own model splits animation work into two paths: (a) built-in animatable modifiers (`scaleEffect`, `opacity`, `shadow`, `offset`, `rotationEffect`...) that SwiftUI interpolates off the main thread without calling your view code, and (b) anything that forces `body` to re-run per frame (custom `Animatable` conformance, `keyframeAnimator`, `TimelineView(.animation)`, a `Timer` driving `@State`). The first path is cheap; the second costs one main-thread body evaluation per frame and is the thing to minimize or isolate in a leaf view.

### Cited Findings

**How SwiftUI runs animations (the model behind "cheap vs expensive")**
- Two distinct paths: state change → body re-evaluation ("If any of its dependencies change, the view is invalidated, and at the close of the transaction, the framework calls body to produce a new value"), versus animation frames handled in the attribute graph: "For built-in animatable attributes like scaleEffect, SwiftUI is very efficient. It's able to do this work off the main thread and without calling into any of your view code." — [WWDC23 "Explore SwiftUI animation"](https://developer.apple.com/videos/play/wwdc2023/10156/)
- Explicit cost warning for custom `Animatable`: "a custom Animatable conformance can be much more expensive to animate than a built-in effect because it'll run body for every frame of the animation. So only use this tool if you can't achieve the effect you're going for using the built-in effects." — [WWDC23 "Explore SwiftUI animation"](https://developer.apple.com/videos/play/wwdc2023/10156/)
- `withAnimation` "is just a thin wrapper around withTransaction"; Transaction is "discarded at the end of every update." Blanket `.transaction` overrides on descendants "can lead to accidental animations"; prefer `.animation(_:value:)`, which "will only write the animation into the transaction if the value has changed," or the closure-scoped `.animation(.smooth) { $0.shadow(...) }` form for generic containers. — [WWDC23 "Explore SwiftUI animation"](https://developer.apple.com/videos/play/wwdc2023/10156/)
- Springs are now the default for a bare `withAnimation` and are recommended because they preserve velocity and retarget smoothly; presets `.smooth`, `.snappy`, `.bouncy`. — [WWDC23 "Explore SwiftUI animation"](https://developer.apple.com/videos/play/wwdc2023/10156/)

**`spring(duration:bounce:)` guidance**
- "It uses just 2 parameters: duration and bounce." Bounce 0 is the default and recommended when unsure; ~0.15 is "a little more brisk," ~0.3 gives "noticeable bounciness," and above ~0.4 "may feel too exaggerated for a UI element." Pick duration first, then bounce. — [WWDC23 "Animate with springs"](https://developer.apple.com/videos/play/wwdc2023/10158/)
- "SwiftUI will now automatically track velocities any time a gesture is changing properties," and retargeted springs reuse current velocity, which is why springs survive interruption without a visible jerk. Do not wait on settling duration; use the completion handler, which "uses a perceptual duration instead of a settling duration." — [WWDC23 "Animate with springs"](https://developer.apple.com/videos/play/wwdc2023/10158/)
- Note: the session never states 0.5 s as a documented default duration; its examples use `duration: 0.5`. — [WWDC23 "Animate with springs"](https://developer.apple.com/videos/play/wwdc2023/10158/)

**`phaseAnimator` vs `keyframeAnimator`**
- "Use phases for chained animations... Use keyframes for more complex animations where you need complete control." — [WWDC23 "Wind your way through advanced animations"](https://developer.apple.com/videos/play/wwdc2023/10157/)
- Keyframes run per frame: "While an animation is in progress, SwiftUI will provide you with a value of this type on every frame," and "updates happen on every frame, so you should avoid performing any expensive operations while applying a keyframe animation to the view." The transcript does not make the same statement about phase animators. — [WWDC23 "Wind your way through advanced animations"](https://developer.apple.com/videos/play/wwdc2023/10157/)
- Keyframes "are not a replacement for normal SwiftUI animations in situations where the UI should be fluid and interactive," and "keyframe animations can't gracefully retarget the way that springs can, so it's generally best to avoid changing keyframes mid-animation." — [WWDC23 "Wind your way through advanced animations"](https://developer.apple.com/videos/play/wwdc2023/10157/)
- `phaseAnimator([false, true])` with a 1 s `easeInOut` loop is shown as an acceptable ambient effect; `KeyframeTimeline` can be evaluated outside a modifier (e.g., inside a `TimelineView`). — [WWDC23 "Wind your way through advanced animations"](https://developer.apple.com/videos/play/wwdc2023/10157/)

**`TimelineView(.animation)` and Canvas**
- `AnimationTimelineSchedule` is documented as "A pausable schedule of dates updating at a frequency no more quickly than the provided interval," i.e., `minimumInterval` caps update rate and `paused` stops updates. — [Apple docs: AnimationTimelineSchedule](https://developer.apple.com/documentation/swiftui/animationtimelineschedule)
- The `.animation` schedule "updates the timeline at a rate suitable for animated content" and your closure receives `context.date`; the recommended pattern computes visuals from the date rather than mutating `@State`, and checks `context.cadence` to reduce detail when updates are less frequent. — [Nil Coalescing: TimelineView](https://www.nilcoalescing.com/blog/TimelineViewInSwiftUI)
- `drawingGroup()` renders a subtree "into an off-screen image before putting it back onto the screen as a single rendered output" via Metal; it fixed a 100-gradient-circle example but "Adding the off-screen render pass might slow down SwiftUI for simple drawing," so it is not a default optimization. — [Hacking with Swift: drawingGroup](https://hackingwithswift.com/books/ios-swiftui/enabling-high-performance-metal-rendering-with-drawinggroup)

**Known expensive patterns (anecdotal, developer forums)**
- A pulsing `Circle` driven by `Timer.publish(every: 0.5)` + `withAnimation(.easeInOut(duration: 0.25).repeatForever(autoreverses: true))` showed CPU climbing over time to ~95% with visible stutter; the accepted answer blames `repeatForever` (re-issued every tick, so animations stack). No Apple reply. — [Apple Developer Forums thread 767243](https://developer.apple.com/forums/thread/767243) (anecdotal)
- A forum title reports "SwiftUI full screen animation uses less energy than Metal Game template"; I did not fetch the body, so treat as a pointer only. — [Apple Developer Forums thread 756273](https://developer.apple.com/forums/thread/756273) (anecdotal, unverified)

**Body cost and dependency rules (WWDC23 "Demystify SwiftUI performance")**
- Updates recurse "only updating those views that have new values or other changed dependencies"; "Try reducing view values to only the data they actually depend on"; `@Observable` "automatically limit[s] the dependencies to only that which is read." — [WWDC23 "Demystify SwiftUI performance"](https://developer.apple.com/videos/play/wwdc2023/10160/)
- `Self._printChanges()` is debug-only, "has a runtime performance impact," and must not ship. — [WWDC23 "Demystify SwiftUI performance"](https://developer.apple.com/videos/play/wwdc2023/10160/)
- Keep `body` cheap: watch "expensive string interpolation or operations like data filtering"; avoid synchronous work in dynamic-property initializers (move to `.task`); cache strings; beware heap allocations. — [WWDC23 "Demystify SwiftUI performance"](https://developer.apple.com/videos/play/wwdc2023/10160/)
- In `List`/`Table`, keep a constant view count per element (avoid `if` without `else`, avoid `AnyView`); move filtering into the model. — [WWDC23 "Demystify SwiftUI performance"](https://developer.apple.com/videos/play/wwdc2023/10160/)

**WWDC25 additions**
- Lists with over 100,000 items on macOS "now load 6x faster" and "update up to 16x faster"; SwiftUI "now schedules UI updates more efficiently" during scrolling; nested lazy stacks defer loading; a new SwiftUI Instruments template has lanes for long view body updates and platform view updates. — [WWDC25 "What's new in SwiftUI" transcript (nonstrict index)](https://nonstrict.eu/wwdcindex/wwdc2025/256/)
- Context: John Siracusa had abandoned SwiftUI List for AppKit in Hyperspace because a several-hundred-item list would not scroll smoothly; Apple's Tahoe changes are the response. — [MacG, June 2025](https://www.macg.co/macos/2025/06/apple-corrige-enfin-un-gros-probleme-de-performances-de-swiftui-302153)
- "Design your data flow to update your views only when necessary, and be extra careful with dependencies that change very frequently"; "It's important to avoid storing values that update really often, such as geometry values or timers, in the environment." — [WWDC25 "Optimize SwiftUI performance with Instruments"](https://developer.apple.com/videos/play/wwdc2025/306/)

### Inferences
- Cheap tier (no body per frame): implicit `.animation(_:value:)`, `withAnimation` on built-in modifiers, `spring(duration:bounce:)`, `.transition` with built-in `AnyTransition` cases, `matchedGeometryEffect` (built-in geometry interpolation). Medium tier: `phaseAnimator` (discrete phases; the view closure runs on each phase change, and interpolation of built-in modifiers between phases should follow the cheap path, though Apple does not state this explicitly). Expensive tier (body or closure per frame on the main thread): `keyframeAnimator`, custom `Animatable`, `TimelineView(.animation)` + `Canvas`, Timer-driven `@State`, `.onContinuousHover` writing `@State` on every pointer move. This tiering is inferred from the "Explore SwiftUI animation" two-path model and the keyframe per-frame statement; Apple does not publish a ranked list.
- `drawingGroup()` and `.layerEffect`/`.colorEffect` Metal shaders shift compositing cost to the GPU but do not stop body re-evaluation; they help when many layers or gradients are composited each frame, not when the bottleneck is body churn.
- `repeatForever` combined with repeated `withAnimation` calls is a specific anti-pattern for idle loops: start the looping animation once (e.g., in `onAppear`) and never re-issue it.

### Gaps
- No Apple source gives millisecond budgets for view bodies; WWDC25 says lanes are colored by "how likely they are to contribute to a hitch or hang" and only remarks that "a millisecond to run a view body may not seem like a long time, but the total time spent can really add up."
- I could not fetch WWDC24 "SwiftUI essentials" (10150) or the WWDC25 Liquid Glass design sessions; their animation-specific guidance is not captured here.
- No primary source measured `.layerEffect`/Metal shader CPU cost on macOS; the sources found (Hacking with Swift, Cindori, Jacob's Tech Tavern) were surfaced by search but not fetched.
- No source quantifies `matchedGeometryEffect` or `rotation3DEffect` cost on macOS.

## Key question 2: Continuously animating mascot (breathing, blinking, eye-tracking, arm sway) — TimelineView+Canvas vs Core Animation vs Rive vs Lottie

### Takeaway
No published head-to-head benchmark exists for macOS. Based on Apple's model, a Canvas redrawn every frame re-runs your drawing closure on the main thread, while Core Animation layer animations (CABasicAnimation on CAShapeLayer, CAEmitterLayer) are interpolated by the render server; Rive runs on its own worker thread with GPU rendering and has a native state-machine/listener model for pointer-driven behavior; Lottie's Core Animation engine offloads playback to CA but does not natively support cursor-tracking rigs. For a rig with eye-tracking and state-driven idle loops, Rive is the only option here whose authoring tool and runtime are built for that, at the cost of an external dependency; a hand-coded CALayer approach is the lightest-dependency route to render-server-driven motion.

### Cited Findings

**Rive (Apple runtime)**
- Supports macOS 13.1+ (also iOS 14+, visionOS, tvOS, Mac Catalyst); MIT licensed; works with UIKit, AppKit, and SwiftUI. — [Rive Apple runtime docs](https://rive.app/docs/runtimes/apple/apple); [rive-ios GitHub](https://github.com/rive-app/rive-ios)
- New runtime SwiftUI usage: wrap a `Rive` object in `RiveUIViewRepresentable(rive)` or `AsyncRiveUIViewRepresentable { ... }`, with `.paused(_:)` and `.frameRate(_:)` modifiers; `RiveViewModel(fileName:).view()` is described as the legacy approach. — [Rive Apple runtime docs](https://rive.app/docs/runtimes/apple/apple)
- Threading: "Each Worker roughly equals one background thread"; for heavy graphics you can create one worker per file; Rive API calls must be on the main actor. Frame rate can be fixed (`.fps(30)`), ranged (`.range(minimum:maximum:)`), or default; ranges behave like fixed rates on macOS below 14. GPU Canvas is enabled via `Worker(configuration: .init(enableGPUCanvas: true))` and is required for 3D content. — [Rive Apple runtime docs](https://rive.app/docs/runtimes/apple/apple)
- State machines are created by `Rive(file:)` and bind authored view-model defaults; for manual data binding, create artboard + view model instance + state machine and retain the instance. — [Rive Apple runtime docs](https://rive.app/docs/runtimes/apple/apple)
- Rive's editor listeners include Pointer Enter, Pointer Exit, Pointer Move ("fires repeatedly while the pointer moves over the target area"), Pointer Down, Pointer Up, Pointer Drag, and Click; Pointer Exit may not fire if the target touches the canvas edge. The docs page does not state which platforms deliver mouse-hover pointer events. — [Rive listeners docs](https://rive.app/docs/editor/state-machine/listeners)

**Lottie (lottie-ios)**
- `RenderingEngineOption.automatic` is the default: "Automatic engine selection (Core Animation with Main Thread fallback)." `coreAnimation` is "GPU-accelerated, with better performance" and lower CPU; `mainThread` is "CPU-based, with high compatibility" and "100% Lottie feature compatibility." The page does not list which features trigger fallback and gives no benchmarks. — [lottie-ios configuration docs (4.5.0 mirror)](https://tessl.io/registry/tessl/cocoapods-lottie-ios/4.5.0/files/docs/configuration.md)
- Deployment target was set to iOS 13.0 / macOS 10.15 in 4.4.2; 4.6.0 requires Xcode 16 / Swift 6.0; `.lottie` v2 (dotLottie) support arrived in 4.5.2; SwiftUI `LottieView` exists and 4.6.1 fixed "animation state loss when the view is removed from a window." No macOS-specific caveats appear in release notes. — [lottie-ios releases](https://github.com/airbnb/lottie-ios/releases)

**Core Animation from SwiftUI on macOS**
- Apple Frameworks Engineer guidance (2026 forum reply) for animating a layer inside an `NSViewRepresentable`: read `context.transaction.animation` and drive AppKit with `NSAnimationContext.animate(currentAnimation) { nsView.layer?.backgroundColor = ... }`, or adopt `Animatable` so SwiftUI drives the value; they also said to retest on macOS 27 where "changes were made in this area." — [Apple Developer Forums thread 832885](https://developer.apple.com/forums/thread/832885)
- Same thread (anecdotal, developer report): on macOS, `NSViewRepresentable` layer changes triggered inside `.onChange` + `withAnimation` snap instead of animating even though `context.transaction.animation` is non-nil; the author's workaround wraps updates in `CATransaction` with `setDisableActions(false)` and a hardcoded duration. — [Apple Developer Forums thread 832885](https://developer.apple.com/forums/thread/832885)

**SwiftUI-native idle loop building blocks**
- `TimelineView(.animation(minimumInterval:paused:))` caps the schedule rate ("no more quickly than the provided interval") and can be paused. — [Apple docs](https://developer.apple.com/documentation/swiftui/animationtimelineschedule)
- `phaseAnimator([false, true])` with `easeInOut(duration: 1.0)` is Apple's own example of an ambient looping effect. — [WWDC23 10157](https://developer.apple.com/videos/play/wwdc2023/10157/)

### Inferences
- Cost model (inferred from the sources above, not measured): a `TimelineView(.animation)` + `Canvas` mascot at 60 fps runs your drawing closure 60 times per second on the main thread, so it must be a leaf view with no `@State` writes and no dependents; using `minimumInterval: 1/30` halves that cost, and `paused:` should be set when the window is occluded or inactive. Core Animation layers (position/transform/path animations on `CAShapeLayer`, particle `CAEmitterLayer`) are interpolated by the render server, so a breathing/sway loop costs near-zero app CPU once started. Rive moves rendering to a worker thread and GPU and offers a supported "pointer move" listener that can drive eye-tracking inside the authored state machine. Lottie's CA engine is similar to hand-coded layers for playback but has no authored input model for cursor tracking; you would drive segments manually.
- Authoring workflow: Rive and Lottie let a designer own the rig; CALayer and Canvas require engineers to hand-code motion. For a character with multiple interacting behaviors (idle + blink + look-at + hover reaction), Rive's state machine and data binding map most directly to the requirement.
- Fidelity: Canvas and CALayer are vector-exact; Rive uses its own renderer (GPU Canvas) and Lottie's CA engine may fall back to main-thread rendering for unsupported features, which could silently raise CPU on macOS.

### Gaps
- No source confirms that rive-ios delivers macOS mouse-move (hover without button) events to Pointer Move listeners; this needs verification in the runtime source or an issue tracker before committing to Rive for cursor-following eyes.
- No measured CPU/energy comparison between Canvas, CALayer, Rive, and Lottie on macOS was found.
- Lottie docs do not enumerate which features force the main-thread fallback; a dotLottie file exported for a mascot would need to be tested with `.coreAnimation` pinned to detect fallbacks.
- No source covers SpriteKit for this use case; it was not researched.

## Key question 3: Documented macOS 26 (Tahoe) SwiftUI pitfalls and workarounds

### Takeaway
I found credible but mostly anecdotal reports: a layout "broken in entirely new ways" complaint from a well-known developer, laggy SwiftUI animations inside `NSStatusItem`/`NSHostingView` since Tahoe, a Liquid Glass compositing cost model (each glass effect needs offscreen passes, mitigated by `GlassEffectContainer`), Menu+Picker dismissal artifacts after building with Xcode 26, and a MenuBarExtra icon disappearance in Tahoe betas that Apple fixed in beta 6 and tied to apps bypassing `NSApplicationMain`. I did not find a documented regression where SwiftUI transactions rebuild the scene, toolbar, or menus.

### Cited Findings
- Marcin Krzyzanowski on the Tahoe RC: "SwiftUI layout is broken on macOS 26, in entirely new ways." — [Mastodon via mjtsai.com roundup](https://mjtsai.com/blog/2025/09/10/macos-tahoe-26-rc/) (anecdotal)
- Steve Troughton-Smith noted a "giant empty toolbar item in Podcasts on Tahoe"; Mario Guzmán (AppKit app) reported toolbars breaking on tab switch and an inspector sidebar not remembering position. — [mjtsai.com roundup](https://mjtsai.com/blog/2025/09/10/macos-tahoe-26-rc/) (anecdotal, some AppKit not SwiftUI)
- "Since macOS 26 Tahoe, even simple animations like a .frame change of a Circle won't animate smoothly even though the same SwiftUI animates normally in a WindowGroup" when the view is an `NSHostingView` inside `statusItem.button`. No Apple reply or workaround in thread. — [Apple Developer Forums thread 803501](https://developer.apple.com/forums/thread/803501) (anecdotal)
- MenuBarExtra/status icon missing on macOS 26 betas: Apple DTS (Kevin Elliott) said engineering knew (r.155484172), the system could not map some processes to bundle IDs, and that bypassing `NSApplicationMain()` "has never really been recommended and it's only become more problematic over time." Beta 6 restored the icon for the poster. — [Apple Developer Forums thread 794920](https://developer.apple.com/forums/thread/794920?page=2)
- Liquid Glass compositing cost: glass is rendered through `CABackdropLayer`s needing extra offscreen passes ("3 offscreen textures" each before final composition); wrapping glass views in a `GlassEffectContainer` cut `CABackdropLayer` count from two to one in the author's test. Reported on iOS 26; the mechanism (CABackdropLayer) is shared with macOS but the article does not test macOS. — [JuniperPhoton: Adopting Liquid Glass](https://juniperphoton.substack.com/p/adopting-liquid-glass-experiences) (anecdotal)
- Same article: `rotationEffect` on a glass view changes its shape mid-animation on iOS 26.0+; Menu morph fixes changed between 26.0, 26.0.1, and 26.1; a `Menu` inside `GlassEffectContainer` breaks morphing on 26.1. — [JuniperPhoton](https://juniperphoton.substack.com/p/adopting-liquid-glass-experiences) (anecdotal, iOS)
- After migrating to Xcode 26, a toolbar `Menu` + `Picker` dismisses with a "capsule-like" animation artifact lingering for seconds; appears on iOS 26.0 and 26.2.1; no workaround or Apple reply. — [Apple Developer Forums thread 820846](https://developer.apple.com/forums/thread/820846) (anecdotal, iOS reported)
- On macOS, `NSViewRepresentable` updates triggered by `.onChange` ignore the SwiftUI transaction's animation; Apple engineer suggests `NSAnimationContext.animate(_:changes:)` with `context.transaction.animation`, adopting `Animatable`, and retesting on macOS 27. — [Apple Developer Forums thread 832885](https://developer.apple.com/forums/thread/832885)
- Severe frame drops resizing a macOS window with a `LazyVGrid` whose column count is recomputed from `GeometryReader`; Apple DTS could not reproduce on Xcode 26.2 / macOS 26.2 and asked for details; unresolved. — [Apple Developer Forums thread 815115](https://developer.apple.com/forums/thread/815115) (anecdotal)
- WWDC25: on macOS, sidebars get a glassy appearance, most toolbar items use Liquid Glass and can morph during navigation, and SwiftUI "now syncs the animation between content and the window when content size changes" with a new window resize anchor. — [WWDC25 256 transcript](https://nonstrict.eu/wwdcindex/wwdc2025/256/)

### Inferences
- The Tahoe-specific pattern across reports is that hosting SwiftUI in AppKit containers (`NSStatusItem`, `NSViewRepresentable`) and Liquid Glass compositing are where animation regressions cluster, rather than ordinary `WindowGroup` content. Apple's repeated guidance is to let SwiftUI drive values (`Animatable`) or bridge the transaction animation explicitly into AppKit.
- Each glass surface adds offscreen render passes; a continuously animating mascot placed under or inside glass will be re-composited every frame with those passes, so keep the mascot outside glass containers or wrap all glass in one `GlassEffectContainer`.

### Gaps
- No source documents a macOS 26 regression where SwiftUI transactions re-evaluate the scene, toolbar, or menu bar; the brief's premise may come from private experience. I searched Apple forums and roundups and found only the layout/status item/toolbar anecdotes above.
- No macOS-specific `searchable`/toolbar re-render or MenuBarExtra binding regression thread was found for 26.x release builds; the MenuBarExtra thread concerns betas and a non-SwiftUI (Qt) process.
- No macOS measurement of Liquid Glass GPU cost exists in the sources; the CABackdropLayer figures are iOS.

## Key question 4: Pointer-following highlights and 3D card tilt on Mac, and rate limiting

### Takeaway
`onContinuousHover(coordinateSpace:perform:)` (macOS 13+) is the supported way to get continuous pointer location; implementations store the point in `@State` and feed `rotation3DEffect`/`position`. No published source gives a recommended rate limit; the only performance-relevant guidance is Apple's WWDC25 warning to keep rapidly changing values like geometry out of the environment and to scope dependencies tightly.

### Cited Findings
- `onContinuousHover(coordinateSpace:perform:)` was introduced in macOS 13 and iPadOS 16; before that, `onHover` only reported enter/leave. It delivers `HoverPhase.active(location)` or `.ended`; local coordinate space is the default, global or named spaces are available. — [mjtsai.com summarizing Natalia Panferova](https://mjtsai.com/blog/2023/02/06/tracking-hover-location-in-swiftui/); [Habr article](https://habr.com/en/articles/718542)
- Reliability bug (anecdotal): John Siracusa reports `.onHover` failing sporadically on a view that does not cover the whole window when the window background is clear; workaround is a non-clear background; filed as FB11988707. — [mjtsai.com](https://mjtsai.com/blog/2023/02/06/tracking-hover-location-in-swiftui/)
- A tilt-card implementation uses `DragGesture(minimumDistance: 0)` with `@GestureState`, maps vertical translation to X rotation (`-height × 0.15`) and horizontal to Y rotation (`width × 0.15`), clamps to ±10°, applies `rotation3DEffect` on X and Y, and resets with a spring on release; flip uses `rotation3DEffect` with perspective 0.7. No performance notes. — [zenn.dev tilt card](https://zenn.dev/touyou/articles/flip_tilt_card_swiftui)
- "SwiftUI will now automatically track velocities any time a gesture is changing properties," so a spring reset after hover/drag ends picks up pointer velocity for free. — [WWDC23 "Animate with springs"](https://developer.apple.com/videos/play/wwdc2023/10158/)
- "Every view that reads the environment depends on the whole EnvironmentValues struct" and "It's important to avoid storing values that update really often, such as geometry values or timers, in the environment." — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/)
- Built-in effects such as `scaleEffect` and `rotationEffect` interpolate off the main thread without running body. — [WWDC23 10156](https://developer.apple.com/videos/play/wwdc2023/10156/)

### Inferences
- A performant Mac tilt card: isolate the hovered card as its own leaf view holding the pointer `@State`; compute normalized offsets (`(x / width - 0.5)`, `(y / height - 0.5)`) and apply `rotation3DEffect` plus a `RadialGradient` highlight positioned at the pointer; attach `.animation(.spring(duration: 0.3), value: hoverPoint)` so SwiftUI interpolates between pointer samples off-thread; on `.ended`, reset with a spring. Because every `onContinuousHover` callback writes `@State`, the card's body runs per pointer event (up to the event rate of the mouse); keeping that body tiny matters more than throttling.
- Rate limiting is not documented by Apple; if needed, a practical approach is to ignore pointer deltas below ~1 pt or to route the sample through `TimelineView(.animation(minimumInterval: 1/60))` so rendering is capped at display rate. This is inference, not a sourced recommendation.

### Gaps
- No source recommends a specific hover event throttle on macOS.
- No source quantifies `rotation3DEffect` with perspective cost on macOS, or whether it triggers offscreen rendering.
- The Habr article did not cover tilt despite the search snippet; the designcode.io hover and rotate3D pages were not fetched.

## Key question 5: @Observable vs ObservableObject to limit invalidation

### Takeaway
`@Observable` tracks dependencies per property read inside `body`, while `ObservableObject` invalidates every dependent view on any `@Published` change; Apple's WWDC25 example reduced a whole-list re-render to two view updates by splitting shared state into per-item `@Observable` view models and marking the backing dictionary `@ObservationIgnored`.

### Cited Findings
- `ObservableObject` notifies at the object level via `objectWillChange`; `@Observable` re-evaluates a view only when a property it read in `body` changes; changing a property read only in a Button action does not re-run body. In the author's example, changing `store.b` re-evaluated only view B under Observation versus Root and B under ObservableObject. — [fatbobman: A Deep Dive Into Observation](https://fatbobman.com/en/posts/mastering-observation/)
- Own the instance with `@State` in the owning view; pass as plain `let`/`var` or `@Bindable`; use `@ObservationIgnored` for properties that should not be tracked; nested observables are tracked at any depth; `withObservationTracking` is one-shot and SwiftUI re-creates tracking on each evaluation, whose cost the author says "still needs evaluation." A class conforming to both protocols responds to both paths under `@StateObject`, only Observation under `@State`. — [fatbobman](https://fatbobman.com/en/posts/mastering-observation/)
- WWDC25 example: rows reading `modelData.favoritesCollection.landmarks` created a dependency on the whole collection, so one favorite change re-ran every visible row; the fix used `@Observable class ViewModel { var isFavorite }` per landmark stored in an `@ObservationIgnored private var viewModels: [Landmark.ID: ViewModel]`, reducing the trace to "only two updates, one for each button." — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/)
- "Even when a body doesn't re-run, there is still a cost associated with checking for updates" for environment readers. — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/)
- Observation "automatically limit[s] the dependencies to only that which is read"; for large structs, not every dependency deserves subview extraction. — [WWDC23 10160](https://developer.apple.com/videos/play/wwdc2023/10160/)

### Inferences
- For a mascot: keep animation-driving values (phase, blink timer, look-at point) out of any `@Observable` object that other views read, or put them in a dedicated `@Observable` owned by the mascot view so only the mascot's body depends on them. Never publish per-frame values through `@Published` or the environment.

### Gaps
- No benchmark quantifies Observation's per-evaluation tracking overhead at 60 fps.

## Key question 6: How to profile and what numbers are acceptable

### Takeaway
Use Xcode 26's SwiftUI Instruments template (SwiftUI instrument + Time Profiler + Hangs and Hitches) in a Release build; inspect the Update Groups, Long View Body Updates, Long Representable Updates, Other Long Updates lanes and the Cause & Effect Graph; Apple gives no millisecond threshold and instead colors updates by hitch likelihood, so the acceptance criterion is "no red updates during the animation and body counts equal to what you expect."

### Cited Findings
- Setup: Xcode 26, device on the latest OS, Command-I for Release build into Instruments, choose the SwiftUI template (includes SwiftUI instrument, Time Profiler, Hangs and Hitches). If CPU spikes with an empty Update Groups lane, the problem is outside SwiftUI. — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/)
- Lanes: Update Groups (when SwiftUI works), Long View Body Updates, Long Representable Updates, Other Long Updates, Cause & Effect Graph (what triggered an update and what it caused). Lanes are colored orange/red by "how likely they are to contribute to a hitch or hang"; "Investigate red updates first." Detail pane has a Long View Body Updates summary filter with per-view counts. — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/)
- Workflow for a long body: select the update, "Set Inspection Range and Zoom," switch to Time Profiler, search the stack for the view name (the session found formatter creation in a computed property). Long updates right after launch may be harmless; focus on those during interaction. — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/)
- Hitch definition: all event handling, body updates, and render handoff must finish before the frame deadline; a late update holds the previous frame, which "makes animations appear less fluid." Many small updates can miss the deadline together even when none is individually long. — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/)
- Method: "analyzing a trace with an idea in mind of what you expect, and looking for anything that seems out of place" (e.g., two taps should update two views); dimmed icons in the graph mean body ran but output did not change. Do not rely on breakpoints; use Cause & Effect. — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/)
- The only timing remark: "a millisecond to run a view body may not seem like a long time, but the total time spent can really add up." No numeric thresholds. — [WWDC25 306](https://developer.apple.com/videos/play/wwdc2025/306/)
- Measure-fix-remeasure loop and the hang vs hitch distinction; see "Analyze hangs with Instruments" and the "Explore UI animation hitches and the render loop" tech talk. — [WWDC23 10160](https://developer.apple.com/videos/play/wwdc2023/10160/)
- `Self._printChanges()` for quick body-cause diagnosis; debug-only. — [WWDC23 10160](https://developer.apple.com/videos/play/wwdc2023/10160/)

### Inferences
- Acceptance criteria for an idle mascot, derived from the above: during the loop, the Update Groups lane should show only the mascot leaf view updating (one body per frame if Canvas-driven, zero if CALayer/Rive-driven); no red or orange entries in Long View Body Updates; Hangs and Hitches track empty; Time Profiler main-thread usage dominated by rendering rather than `body`. Reduce `TimelineView` to `minimumInterval: 1/30` if the Update Groups lane shows the mascot body exceeding a fraction of the 16.7 ms frame budget at 60 Hz.

### Gaps
- Apple publishes no acceptable "View Body count per second" or per-body millisecond target; any such number in the final report would be an engineering heuristic, not a sourced figure.
- The "Animation Hitches" template specifics (hitch duration thresholds) were not researched beyond the WWDC25 session.
