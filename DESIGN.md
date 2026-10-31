# Grove Design System & Visual Audit

> Status: canonical visual-design contract
> Purpose: this document is the reason Grove looks and feels like **one** product. It records the visual audit that unified the app, the principles reverse-engineered from award-winning apps, and the rules every future screen must follow. If a visual decision isn't representable with the tokens below, the tokens change first — the screen never improvises.
>
> Code home: [`Grove/DesignSystem.swift`](Grove/DesignSystem.swift) (tokens, elevation, motion, chrome) and [`Grove/Components.swift`](Grove/Components.swift) (shared components).

## What award-winning apps do that most apps don't

Apple Design Award and equivalent winners (think of the calm coherence of Headspace, the material honesty of Things, the play-with-discipline of Duolingo, the editorial confidence of Airbnb) are not unified because their designers had better taste on every screen. They are unified because they made a small number of decisions **once**, encoded them, and then refused to make them again per-screen:

1. **One canvas.** A single signature ground color that every screen sits on. The moment two screens have subtly different "white," the product feels stitched together.
2. **One type voice.** A display voice for moments, a text voice for everything else — and nothing else. Headings never vary in personality between tabs.
3. **Semantic color, never literal color.** No screen ever picks "a nice orange." It picks *the streak flame*. When a color means something (health, danger, celebration, progress), that meaning has exactly one hue in the whole app.
4. **A geometry scale you can count on one hand.** Radii, spacing, and shadows come from a scale so small that any two components automatically rhyme.
5. **One physicality.** Everything moves with the same springs. Motion is how an app tells you it's a single object and not a bundle of screens.
6. **Play is themed, not exempt.** Gamified areas (Duolingo's path, Nike Run Club's trophies) look like *the product having fun*, not a licensed mini-game. Illustration gets its own governed palette; interface on top of it stays on-system.
7. **The signature control.** Award-winning apps have one unmistakable primary action treatment used everywhere (Duolingo's chunky button, Things' blue plus). Users learn it once and trust it forever.

The audit below measured Grove against those seven behaviours, and the fixes made each of them literally true in code.

## Audit findings (and what changed)

### 1. The signature CTA had rivals — *fixed*

Grove's signature primary action is the **ink pill with the circular arrow** (`GroveCTALabel`). The audit found three competing primary-button languages shipping alongside it:

- Green rounded-rectangle buttons in the Journey (milestone complete, action CTA, "Keep growing"), collection creation, and the location picker.
- System `.borderedProminent` buttons in scan/camera permission states and the photo-privacy sheet.
- Assorted one-off capsules.

**Now:** every primary action on the cream canvas is the ink CTA pill. On camera-black surfaces the same pill flips to its white `onDark` form. Secondary actions are stroked capsules. Native controls remain only inside native contexts (Forms, alerts, `ContentUnavailableView`), where matching the OS *is* the correct design.

### 2. "Celebration gold" was improvised six different ways — *fixed*

The crown after a check-in, the Journey's gold road, the reward pucks, the XP bolt, the node glow, and the badge spray each used a different hand-mixed gold; the streak flame was `.orange` in one tab, `warning` amber in another, and a third orange in a third place.

**Now:** three semantic tokens carry all of it:

| Token | Meaning |
| --- | --- |
| `GroveTheme.gold` | Celebration: crowns, reward pucks, the gold road, glows, sparkles |
| `GroveTheme.goldDeep` | Gold's gradient partner; gold on materials that needs contrast |
| `GroveTheme.streak` | The streak flame — every flame in the app, one temperature |

`warning` is now exclusively a *caution* color again. Celebration and caution no longer share a hue anywhere.

### 3. Health colors were half in, half out of the system — *fixed*

Three of the five health bands were hardcoded RGB in the data model, didn't adapt to dark mode, and didn't share DNA with the brand's accent greens. Plant artwork palettes were likewise raw RGB with no dark variants, and colour lived *inside `DomainModels`* — the data layer was making presentation decisions.

**Now:** `HealthBand.color`, `HealthTrend.color`, and `PlantPalette.colors` live in `DesignSystem.swift`, are dark-mode adaptive (artwork gradients lift slightly in dark so they keep depth on the near-black canvas), and the green bands sit in the accent family. `DomainModels.swift` no longer imports SwiftUI at all — models are presentation-free by construction.

### 4. Elevation was ad hoc — *fixed*

Ten different shadow recipes (radius 4–18, offset 2–10) made cards feel like they floated in different atmospheres per screen.

**Now:** three elevation levels, applied with `.groveShadow(_:)`:

| Level | Use |
| --- | --- |
| `.resting` | Cards in grids and rows |
| `.floating` | Prominent standalone cards (the `groveCard()` default) |
| `.hero` | The page-top hero surface |

Permitted exceptions, on purpose: colored glows (celebration gold, accent bloom), on-photo/dark-surface legibility shadows, and the tab bar's upward shadow.

### 5. Eleven corner radii → four — *fixed*

`6, 8, 9, 10, 12, 14, 16, 18, 20, 28, 30` were all in use. **Now** the scale is:

| Token | Value | Use |
| --- | --- | --- |
| `compactRadius` | 12 | Chips, small fields, thumbnails |
| `insetRadius` | 16 | Tiles and choice rows nested inside cards |
| `cardRadius` | 22 | Cards |
| `heroRadius` | 28 | Heroes and full-bleed sheets |
| `pillRadius` / `Capsule` | ∞ | Pills, CTAs, progress tracks |

Selectable "choice rows" (scan candidates, quiz options, onboarding answers) previously used three different radii — they are now one family at `insetRadius`. Remaining literals are deliberate: chart bar marks and the camera focus ring (hardware idiom).

### 6. Motion had twelve spring curves — *fixed*

**Now:** a five-word motion vocabulary in `GroveMotion`; interface animation picks from it and nothing else:

| Token | Feel | Use |
| --- | --- | --- |
| `press` | tight | Touch feedback (built into `GrovePressStyle`) |
| `snap` | quick | Selection: tabs, filters, chips |
| `settle` | calm | Content settling: expansion, insertion |
| `reveal` | composed | Results and big content appearing |
| `celebrate` | bouncy | Celebration pops — the only bouncy spring |

Fades (`easeInOut`) remain for opacity-only transitions; springs are for things that *move*.

### 7. The Journey was a beautiful foreign country — *fixed*

The gamified map is intentionally illustrated — that's right for it. But its **interface** (HUD, buttons, node states, XP bars) had drifted into its own colors and shapes, and its scenery values were scattered through five hundred lines.

**Now** the boundary is explicit and enforced:

- **UI on the map is `GroveTheme`:** the HUD flame is `streak`, XP is `goldDeep` on the shared `GroveProgressBar`, active nodes wear the accent gradient, reward pucks wear `gold → goldDeep`, and the overlay buttons are the signature CTA pill.
- **Scenery is `JourneyWorld`:** one documented illustration palette at the top of `JourneyMapView.swift`. It now carries two families — per-biome ground, hill, and flora colours for the five chapter regions, and the object colours (timber, iron, glass, roof tile, pond water, lantern glow, animal coats) that every keepsake and chest is drawn from. Illustration may be storybook; it may not be scattered.
- **Sprout** (the mascot) now wears the brand accent gradient, so the character literally shares the product's DNA.
- **Keepsakes and chests are art, not chrome:** drawn entirely in SwiftUI from `JourneyWorld` values in `JourneyKeepsakes.swift` and `JourneyChest.swift`, so the world costs no asset weight and re-tints itself for dark mode. Any UI *on top* of them — reward cards, the chest ceremony's CTA, the chapter banner — stays on `GroveTheme`.

### 8. Repeated micro-patterns are now components — *fixed*

- `GroveProgressBar` — the one capsule progress track (XP, course progress, sitting tasks, onboarding). Previously five hand-rolled bars with three heights.
- `GroveSymbolTile` — the icon-on-soft-green tile, now used everywhere the pattern appears instead of being re-derived with slightly different radii.
- Hairline strokes are 1 pt `separator` on cards (0.5 pt was mixed in arbitrarily).

### 9. Onboarding — *verified, and fenced*

`OnboardingTheme` is an alias layer over `GroveTheme` (good), and is now documented as **strictly** that: it may rename tokens, never mint them. Its choice rows and inputs joined the app-wide `insetRadius` family and its progress bar is the shared component.

### 10. Page anatomy had four dialects — *fixed (second audit, Jul 2026)*

Token hygiene alone didn't make the pages *feel* related: each screen still assembled its header, title bar, section titles, and margins its own way.

- **Display type had twelve sizes.** `GroveDisplayHeading` was called at 20, 22, 24, 26, 28, 30, 32, 34, 36, 38, 44, and 46 pt. **Now** the display voice has exactly five steps (`GroveDisplayStyle`): `hero` 46 (tab-root identities, full-bleed heroes), `title` 40 (page/sheet headers), `heading` 34 (overlay moments, banner titles), `section` 26 (section and card-hero titles), `card` 22 (titles inside cards and tiles). `GroveDisplayHeading(text:style:)` is the only spelling; the raw-size initializer survives strictly as a measured escape hatch.
- **Top bars spoke three languages.** Tab roots used the transparent editorial bar, some pushed screens hand-rolled the same three modifiers, and half the app fell back to system SF-Pro titles — so drilling in switched brands. **Now** two modifiers cover every screen: `.groveEditorialPage(title)` (ink `GroveHeaderTitle` on the transparent bar — all cream-canvas scroll pages) and `.grovePageTitle(title)` (same ink title, system bar behavior — native List/Form contexts). Tab roots keep `.groveHeaderBar()` with their in-content header.
- **Page headers were improvised.** `GrovePageHeader` had zero call sites. **Now** it is the one in-content header — accent eyebrow, display title, muted subtitle, optional trailing accessory (Ask's streak pill) — used at `.hero` on tab roots (Ask, Friends) and `.title` on sheets (Invite a friend).
- **Section titles had two voices.** Today used `SectionHeader` while Profile and the old Learn tab hand-rolled display headings with ad-hoc trailing rows. **Now** `SectionHeader` (with an optional trailing slot for counts and "New" buttons) is the only section treatment; `GroveEyebrow` remains the quiet small-caps label for minor groupings.
- **Filters had two controls.** Updates used a system segmented picker while Today and My Grove used underline tabs. **Now** `GroveUnderlineTabs` is the only on-canvas filter control.
- **Margins wandered.** Top padding 4–12, bottom 24–48, section gaps 16–28. **Now** every scroll page breathes identically: `pageTopPadding` (8) above, `pageBottomPadding` (40) below (pages with a pinned bottom action bar keep a tighter inset), `sectionSpacing` (28) between sections.
- **Chrome icons matched nothing.** Raw `Image(systemName:)` toolbar buttons shipped next to `GroveHeaderIcon`. **Now** editorial screens use `GroveHeaderIcon` for every bar action; native contexts keep native controls.

### 11. The signature CTA had *quiet* rivals, and four screens didn't fit — *fixed (third audit, Jul 2026)*

Round two unified page anatomy. Walking the app screen by screen afterwards found the drift had moved into two places tokens can't reach: the buttons that *aren't* the hero CTA, and layouts that only break on a small phone.

**Buttons below the hero.** The signature pill was honoured, but everything under it was hand-rolled: a solid-ink capsule appeared five times (friend requests ×2, the check-in camera, "Confirm this match", "Refine with my answers") in three different type sizes and heights, a stroked capsule appeared four times, and the camera-black screens fell back to a plain white capsule with `.black` text. **Now** there are exactly two secondary components, each with a label form for `ShareLink` / `PhotosPicker` / `NavigationLink` hosts:

| Component | Use |
| --- | --- |
| `GroveInkButton` / `GroveInkLabel` | Confirmation *inside* a card, step, or row — the CTA's ink and capsule without the circular arrow, which would wrongly promise navigation |
| `GroveOutlineButton` / `GroveOutlineLabel` | The one secondary treatment; `onDark: true` for camera-black and full-colour surfaces |

`GroveButtonSize.regular` is 62 pt tall — exactly `GroveCTALabel`'s height — so a secondary action paired with or stacked under the signature pill reads as its equal instead of a shrunken version of it; `.compact` hugs its label for row-trailing actions. Native controls still stay in native contexts (`List`, `Form`, `ContentUnavailableView`) — the one bordered button that had escaped onto the cream canvas (a care task's "View profile") is now a stroked capsule.

**`onDark` was a claim, not a fact.** `GroveCTALabel(onDark:)` had *zero* call sites, and would have failed at all four of them: every surface that wants it (`ScanView`, `GroveCameraView`) forces `.preferredColorScheme(.dark)`, where the adaptive `ink` flips to cream — white text on a white pill. `GroveTheme.inkOnLight` is the fixed near-black for content on fixed-white surfaces, and the on-dark pill is now real on the camera permission states, the retry after a failed capture, and the level-up takeover.

**One docked action bar.** The page-committing action sat on five different backgrounds: a fading gradient, a 94%-opaque canvas, a hard `surface` band with a divider, `.bar` material, and nothing at all. **Now** `.groveActionBar()` is the only bottom bar.

**Layouts that only broke on a small phone.** Four were real clipping bugs, not preferences:

- **Welcome screen** — badge, logo, 40 pt promise, three 60 pt auth pills and the legal footer need ~700 pt; a 4.7" screen has ~647. It now scrolls when it must and keeps its centred composition when it doesn't.
- **The email / code sheet** put its primary button under the home indicator: it ignored the bottom safe area with 20 pt of padding.
- **Check-in, step 2** was a fixed 360 pt frame plus a heading, two buttons and a caption inside a step area of ~463 pt on a 4.7" screen — laid out between a fixed header and a fixed footer, with no scroll view. It scrolls now.
- **The check-in celebration** hid its findings card behind the floating "Done" button; the button is docked with `safeAreaInset`, so content ends above it.

**Collisions and rhythm.** The Today hero's plant chip and stat pills were opposing overlays, so a long nickname grew its chip underneath the pills — they share one row now. Home's four quick-action tiles needed 76 pt each inside 74.75 pt; `GroveActionTile` is sized to fit four across at 375 pt (and no longer carries the app's only radius-18 corner). A plant's diagnosis timeline drew a fixed 62 pt rail between dots that sit ~100 pt apart, so the timeline read as broken; the rail stretches. Plant sitting's "Assignments" heading floated as far from its own list as from the section above it.

**Remaining token drift, swept.** A sixth and seventh display size (28 pt profile metrics, 48 pt health score) now take steps from the scale; two 0.5 pt hairlines became 1 pt; ten `RoundedRectangle`s were still circular-cornered next to continuous-cornered cards; onboarding's `.snappy` / raw springs joined the motion vocabulary; `OnboardingTheme`'s radii and page padding alias `GroveTheme` instead of repeating its numbers; Sprout's face ink moved into `JourneyWorld`; the Journey's toolbar button became a `GroveHeaderIcon`; and the species search sheet — the one `List` without `groveGroupedContent()` — stopped rendering on system grey.

**Two dead Settings rows.** "Blocked accounts" and "Sign in & security" looked like destinations and did nothing when tapped. The first states the fact it has (`None`); the second is gone, since the account row above it is what the screen can honestly say today.

### 12. Settings said things it could not back up — *fixed (fourth audit, Jul 2026)*

Rounds one to three unified how the app *looks*. Walking Settings row by row found the drift had moved somewhere tokens cannot reach at all: what the rows **claim**. A settings screen is where a user goes to check what is true about their account, so a row that states an aspiration instead of an observation costs more trust than a mismatched radius ever could. `SettingsView` also still lived at the bottom of `ProfileView.swift`; it is its own screen now, in `Grove/SettingsView.swift`.

**Rows that stated instead of observed.**

- **"My Grove — Private" was hardcoded.** The real setting is `profile.isPrivate`, edited in Edit profile. A user who had deliberately made their profile discoverable was still told their Grove was private. The row reads the actual value and pushes to where it is changed.
- **"Check-ins — Private by default"** described a default rather than the model: sharing is per-plant. A new row answers the question the screen is actually opened to ask — *who can see my plants right now* — by counting live sitting assignments and the plants they name, one tap from the assignment itself.
- **The two Safety rows were bare `Label`s** with no substance behind their titles. Grove gives health guidance about living things people eat, brew, and keep around pets; the limits of that guidance are now readable in the app, in native `DisclosureGroup`s, with the "not a medical, veterinary or horticultural service" line where the section can't be missed.

**Destructive actions that did not warn.** "Sign out" fired immediately. For a local-only account that is *irreversible data loss*: the Grove is keyed by a UUID minted at onboarding, so nothing on the next launch can name it again and the plants, photos and history are stranded on disk permanently. `SessionService.canRestoreCurrentAccountAfterSignOut` decides which of two confirmations the user sees, and the unrecoverable one offers to prepare an export first. "Reset demo data" — which discards everything the user changed while exploring — now confirms too.

**"Delete everything" left things behind.** Preferences and the recorded photo-processing consent live outside the account snapshot, so a wiped device kept agreeing to photo processing on the user's behalf and handed its reminder schedule to whoever signed in next. Those keys are named once in `GroveDefaults` and cleared by the delete path. A prepared export — a plaintext copy of the whole account graph — is now also discarded on **sign out**, not only on delete.

**Missing production surface.** No version, no privacy policy, no terms; App Review requires the policy to be reachable from inside the app, not only from a sign-up screen the user passed weeks ago. The links live in `GroveLegal` so onboarding and Settings can never drift apart, and "Copy diagnostics" hands support the build, account, sync and notification state in one paste — with no plant data, photos or location in it.

**One real setting added.** Reminders fired at a fixed 09:00, so the hour was the app's opinion rather than the user's. `NotificationService` takes a delivery hour (clamped, because `@AppStorage` reads a missing value as `0` and would silently move every reminder to midnight) and Settings offers it in the device's own clock format.

**Native-context polish.** Explanatory captions that were `Text` rows became `Section` footers — the native idiom, and they stop looking like tappable rows. Busy actions ("Retry sync", "Prepare data export") keep their label and gain a spinner instead of swapping titles, and both disable while running so an impatient second tap can't queue a duplicate drain of the same queue. Settings also speaks the haptic vocabulary now rather than being the one silent surface left: `toggle(on:)` under the reminder switches, `selection()` under the delivery-hour picker, and `success()` / `error()` when an export finishes — which matters most there, because a large Grove takes long enough to prepare that the user has already looked away.

### 13. Coherent is not the same as unmistakable — *fixed (fifth audit, Jul 2026)*

Audits one to four made Grove *one* product. Walking it afterwards as a stranger — the way a jury would — found the remaining problem was the opposite of drift: everything agreed with everything else, and none of it was ours. A cream canvas, one leaf green, uppercase condensed headings, soft cards and SF Symbols is the house style of most of the category. The system was working; it was just building someone else's app very consistently.

Five changes, each aimed at a place where Grove was reaching for something off the shelf.

**The display voice was borrowed.** Headings were set in uppercase `HelveticaNeue-CondensedBlack` — a legacy bundled face, behind a silent fallback to system-black that would have changed the app's entire personality if the face ever went away, and the single most-used indie-editorial setting of the last five years. The display voice is now **Fraunces Soft Bold, in title case**, bundled under the SIL Open Font License. Its soft terminals and unconventional details feel grown rather than engineered, while SF Pro keeps controls and care guidance completely native and legible.

- Type scale retuned, because a serif sets about a third wider than a condensed face and carries more apparent weight: `hero` 44, `title` 36, `heading` 30, `section` 24, `card` 20.
- Tracking now *closes up* as size goes up (`GroveTheme.displayTracking`), the opposite of what the uppercase setting wanted.
- Display type answers Dynamic Type for the first time: `UIFontMetrics` scales it, capped at 1.4× so a hero heading still fits its card.
- `GroveEyebrow` is now the app's **only** uppercase voice, and it carries the other half of the pairing — sans small-caps under a serif headline is the classic editorial setting.
- `GroveHeaderTitle` joined the display face. The bar is the one piece of type that follows you from screen to screen, and it was switching to a heavy system sans on the way in.

**The subject of the app had no form.** Wherever a photo was missing, `PlantArtwork` drew a gradient with an SF Symbol on it — the same glyphs Apple ships to everyone, standing in for the one thing that is supposed to be ours. `PlantPortrait` now draws the plant in `Canvas` from its own record:

- **Deterministic** — seeded from the plant's `id` via FNV-1a over the UUID's bytes (not `hashValue`, which Swift re-seeds every launch), so a plant looks like itself forever.
- **Diagnostic** — growth habit comes from the species palette (ferns hold many fine fronds high, `sunset` arches and trails on purpose, `moss` is low and dense), and posture comes from health: a struggling plant reaches less far, carries fewer leaves, and lets the ones it has fall.
- **Optically sized** — the crown thins for small frames, so the drawing is a plant at 220 pt and still a plant at 30 pt.
- **Free** — geometry, so it costs no asset weight, re-tints for dark mode, and is sharp at any size.

`PlantArtwork` survives only as the honest stand-in for a plant Grove does not have yet (a scan still resolving), where a glyph is the correct drawing.

**Every navigation was a stock push.** Two `matchedGeometryEffect` uses in eleven thousand lines of view code, and zero navigation transitions: tapping a plant threw away the photograph the user was looking at and redrew it one screen to the left. Because `AppRoute` is `Hashable` and all destinations are built in one place, the fix is systemic rather than per-screen — `.groveHeroSource(route)` on the thing tapped, and `AppDestinationsModifier` zooms into it. Each `NavigationStack` owns its own `Namespace`, because five tabs can all be showing a card for the same plant. Only routes reached by tapping a *picture of themselves* opt in (`AppRoute.zoomsFromSource`); a route pushed from a notification keeps the standard push, which is the right transition for arriving from outside.

**The best idea in the product was locked in a drawer.** The Today hero tinted its photograph warm at dawn and deep blue at night — which is most of why it read as a window — and it knew that privately, inside one 260 pt card. `GroveAtmosphere` now owns the hour and the whole canvas reads it, at a quarter of the photographic strength so the cream stays *the* cream. `GroveTilt` replaces the hero's private `CMMotionManager` with one reference-counted source, so a plant's own page is a window too without a second subscription to the gyroscope.

**Everything was flat.** Cream, soft shadow, cream — with the depth vocabulary of the current OS unavailable behind an iOS 17 floor.

- Deployment target raised to **iOS 18**, which is also what the zoom transitions need.
- `groveShadow` draws **two** shadows per level now: a tight contact shadow under a diffuse ambient one. Still three levels, still one spelling.
- Cards are lit from above: `groveEdgeLight()` strokes them in a gradient from `edgeLight` to `separator` instead of one flat outline all the way round. An outline is the edge of a shape; this is the edge of an object.
- Bar chips become **real glass** on iOS 26 (`GroveChipSurface`), which is what an opaque disc on a transparent bar was always imitating. Earlier releases keep the disc as a correct fallback, not a degraded one.

The tab bar was left alone deliberately: it is a sibling below the pages rather than an overlay, so there is nothing behind it for a material to reveal, and the structure that guarantees that is the same one that keeps the camera's shutter from laying out underneath it.

**Today never introduced itself.** It was the only tab root with no in-content header: the page's first piece of type was a location label sharing the navigation bar with two icon chips, so Grove's home screen opened on a place name that belongs to the weather. Four changes, all of them ordinary house style applied to the one page that had skipped it.

- A `title`-sized display heading — **"Today"** — opens the page, with the location link beneath it as the grove being shown rather than as the screen's name. `.hero` was available and wrong: the hero card's "Hey, Alex." is the emotional payload and has to stay the largest thing on the fold.
- The location glyph is a **house**, not a map pin. This control names where the grove *lives*; a pin reads as "where you are now", which is the one thing it never means — the case Grove's travel handling exists for is precisely a user reading their grove's forecast from an airport.
- The three camera intents are **one card split by hairlines** (`GroveActionColumn`) instead of three separately bordered tiles. Three outlines put six vertical rules across the page for a single row of one kind of thing, and the gaps read as three unrelated features; a segmented card says "one control, three ways" in its shape, and gives each column its width back so "What's wrong?" sets on one line.
- The all-clear row names a date, and now **opens the schedule behind it** — a disclosure chevron and a push to the care queue, for one glyph.
- The week chart labels its days **`MON`–`SUN`** and threads a dashed line between the markers. Seven bare initials are a code with two Ts and two Ss in it; seven unconnected circles are seven facts, where a thread through them is a week.

### 14. The ground was doing more harm than work — *fixed (sixth audit, Jul 2026)*

Audit 13 named a cream canvas as one of the five things that made Grove look like every other app in the category, then kept it — the parchment came from the app icon, which made it feel earned rather than borrowed. Two findings changed that.

**The canvas was never tinting; it was averaging.** `GroveBackground` laid the time-of-day gradient over the ground as a plain alpha mix, while `photoWash` — the same idea, nine lines earlier in the same file — used `.blendMode(.overlay)`. Violet and navy are darker than any canvas Grove has had, so the average was always a step toward grey: 3.4% of dusk violet pulled #F4EDDF to #F0E9DF and 4.8% of night navy took it to #EAE4DB. The top of every screen went dusty after 5pm while the bottom, where the gradient had faded, stayed clean. It read as a rendering fault rather than as evening. Fixed by copying the one line that mattered, sealed with a `.compositingGroup()` so the blend cannot reach past the background modifier into whatever the window puts behind the view.

- Strengths were recalibrated twice: once because a correct blend costs no lightness and the old ceiling existed only to limit the damage, and again when the ground changed, because overlay's reach scales with the base's distance from white.
- `nightCanvasTint` is new. Overlay preserves luminosity, so a dark navy over a light ground has nowhere to go — on bone it produced #ECF0F0, which is not evening, it is a dirty screen. The canvas gets the same blue held at its own lightness; the hero photograph keeps the navy, where the image supplies the darks.

**The parchment cost more than it returned.** #F4EDDF is 92% lightness at ~49% HSL saturation — dark and chromatic for a ground. White cards had to fight 6.4 points of lightness to look raised, green foliage sat on a yellow field that pulled it olive, and the app read dim next to anything else on the phone. The ground is now **cool bone** (#F1F3F0, ~95% lightness, near-neutral) with white cards. Card separation lands at 5.3 points, close to the ~4 of the reference screens this was measured against.

The warmth was a real thing to lose, and it is lost knowingly. It survives where it was doing work someone chose — the icon, the illustrations, the Journey artwork — rather than underneath every screen at once. Chosen on-device from four candidates rendered live, because two grounds four points of lightness apart look identical in a PNG and nothing alike held at arm's length under a lamp.

### 15. Four tabs, four apps — *fixed (seventh audit, Sep 2026)*

Audits one to fourteen unified the tokens, the type, the buttons and the ground. Put the four root tabs side by side afterwards and they still read as four products that shared a palette. Nothing here was a token problem; all of it was *anatomy*: each root assembled its top third its own way, and the top third is the only part of a tab a person sees when they switch to it.

**Three roots opened on a raised sheet; Today did not.** Ask, Friends and My Grove drew a white `groveRootSurface()` under a 302pt `GroveRootHeaderBackdrop`, so their first line of type sat behind a sage crest and an upward shadow — at three different heights, because Friends also hung a system search bar between the bar and the sheet. Today sat flat on its own warmer paper (`todayCanvas`, #FAF8F3 against the app's #FAFBF8: the "two whites" fault this file opens by naming). **Now** there is one canvas, one paper and no sheet. Every root is a scroll page like every other scroll page: `pageTopPadding` above, `pagePadding` at the sides, `sectionSpacing` between sections.

**Four headers.** Today opened on a date caption, a week strip and a location card, and said hello fourth, inside the hero. Ask and Friends opened on a 44pt `.hero` heading. My Grove opened on the owner's name at 36pt beside a 56pt avatar, with "My Grove" only in the bar. **Now** all four open on `GrovePageHeader` at the `.title` step — the greeting on Today, the tab's own name on the other three, so the tab you tapped and the page you landed on always say the same word — with one accessory in its slot (the weather on Today, the avatar on My Grove) and one muted line under it (the date and the grove's place on Today, the friend count on Friends, the grove's state on My Grove).

**Four bars.** Today's chips hid their glass (`sharedBackgroundVisibility(.hidden)`) while the other tabs' chips showed it; Today carried an avatar that was a second door to the My Grove tab; Friends put Invitations in the page as a text link; Ask's history button was a raw symbol beside three tabs' `GroveHeaderIcon`s; and the brand mark stood in the centre of all four, above pages that already open with their own name. **Now** the bar is the same object on every root — streak leading, up to two `GroveHeaderIcon` chips trailing, nothing in the centre — and the `g` lives where a mark belongs: the icon and the My Grove tab glyph.

**Three section voices.** My Grove's sections were `SectionHeader` display headings, Ask's were grey `.headline` text, Friends' were tracked-caps `GroveEyebrow`s. **Now** `SectionHeader` is the only section voice on the roots; `GroveEyebrow` stays inside cards, where it labels a card rather than a page.

**Four card styles on one page.** Ask's suggestion cards were outlined at 16pt; My Grove's attention rows were elevated and edge-lit at 12pt while its plant rows were bare; Friends' cards were outlined at 22pt with a filled inset box inside each; pending invitations were filled at 16pt. **Now** an object on a root is a `groveCard()` — white, one hairline, `cardRadius` — or it is a plain row. Elevation is spent on exactly one thing per page: the Today hero.

**One plant, two faces.** The attention shelf drew `PlantPortrait` while the library two sections below drew the plant's photograph, so the same plant changed face halfway down My Grove. **Now** every plant on a root is its photo.

**The hero spoke a third type voice** — its headline was set in New York, the only serif in the app — under a greeting that is now the page title, above a white capsule labelled "Get started" that existed nowhere else. **Now** the headline is the display face at the `heading` step, the button is the green pill every other primary action wears, and it reads "Take a look": the product's rule in three words.

**Copy that was data.** "Ready for an explicit plant-sitting link" on every friend, "1 of 2 free friend spots used" under the Friends title, a second capsule in Ask's composer explaining what Ari reads. All three are gone from the roots: the first said nothing a person acts on, the second is a paywall line at the top of a tab and belongs beside the invite button, and the third is answered on the conversation screen.

## The system at a glance

**Canvas & ink.** Cool bone ground (`background`, #F1F3F0), white raised surfaces (`surface`), a step-below inset (`secondarySurface`); near-black warm ink with two muted steps. Light is the hero; dark is first-class. The canvas carries the hour: `GroveAtmosphere` washes it warm at dawn and blue at night — through an **overlay blend**, which is what keeps a tint a tint rather than an average of the ground and the tint — faintly enough that you could not name it in a screenshot and unmistakably enough that opening the app twice in a day feels different.

**Accent.** One vivid leaf green (`accent` / `accentStrong` / `softAccent`) used for signals, selection, and life — never for primary buttons. Primary buttons are ink.

**Type.** A serif display voice (`GroveTheme.display` — Fraunces Soft Bold) set in **title case** for editorial moments via `GroveDisplayHeading`; SF Pro system text styles for everything else. No raw `.system(size:)` headings. Display headings come in exactly five sizes via `GroveDisplayStyle` — `hero` 44, `title` 36, `heading` 30, `section` 24, `card` 20 — and nothing in the app types a sixth. `GroveEyebrow` is the app's only uppercase voice, and its tracked sans small-caps are the display serif's deliberate counterweight.

**The plant.** Drawn, not borrowed: `PlantPortrait` renders a plant from its own id, species palette and health. Governed by `Botanical`, which holds habits, light and motion — and deliberately no colour, because portraits are drawn from `PlantPalette.colors` lifted toward white or pushed toward black and so can never leave their card's family.

**Page anatomy.** Every screen is one of three shapes. *Tab root:* `.groveRootHeaderBar()` chrome (streak leading, up to two `GroveHeaderIcon` chips trailing, nothing in the centre) + an in-content `GrovePageHeader` at `.title` with one accessory, flat on the canvas. *Editorial page* (pushed screens and sheets on the canvas): `.groveEditorialPage(title)`. *Native context* (Lists, Forms): `.grovePageTitle(title)` with native controls inside. Scroll pages pad `pageTopPadding` / `pageBottomPadding` vertically and `pagePadding` horizontally, with `sectionSpacing` between sections; sections open with `SectionHeader`; on-canvas filters are `GroveUnderlineTabs`; bar actions are `GroveHeaderIcon`.

**Signals.** `warning` (caution amber), `danger` (red), `purple` (sitting), `gold`/`goldDeep` (celebration), `streak` (flame), health-band greens/ambers, and on-photo variants (`onPhotoImproving` / `onPhotoDeclining`) for legibility over imagery. Time-of-day hero tints: `dawnTint` / `duskTint` / `nightTint`, plus `nightCanvasTint` — the same night blue held at the canvas's lightness, because a navy that is right over a photograph only dirties a light ground.

**Chrome.** `groveBackground()`, `groveCard()`, `groveRootHeaderBar()` / `groveHeaderBar()` + `GroveHeader*` for the transparent top bar (bar chips are real glass on iOS 26), `GroveSearchBar` for the one in-content search field, `groveActionBar()` for the docked bottom action, the system tab bar with `GrovePrimaryActionButton` raised through it.

**Depth & motion between screens.** Three elevation levels, each drawing a contact shadow under an ambient one, with `groveEdgeLight()` lighting a raised surface's top edge. Destinations that are reached by tapping a picture of themselves grow out of it: `.groveHeroSource(route)` on the source, zoom applied centrally in `AppDestinationsModifier`. Photographic surfaces drift with the device via `groveParallax(depth:)`, reading one shared `GroveTilt`.

**Buttons.** `GroveCTAButton` (signature ink pill, `onDark` over photos and colour) → `GroveInkButton` (in-card confirmation) → `GroveOutlineButton` (secondary) → plain text button (tertiary). Both secondary components have `…Label` forms for `ShareLink`, `PhotosPicker` and `NavigationLink` hosts, and `GroveButtonSize.regular` matches the signature pill's 62 pt height.

### 14. Every list was its own product — *fixed (sixth audit, Sep 2026)*

Audits one to five made Grove one product screen by screen. Reading Ask, Today and My Grove **as one session** — the three tabs a user actually moves between in a minute — found the remaining drift in the place a per-screen audit cannot see it: the same object, said differently on each page.

**A plant had four bodies.** One plant appeared as a 52 pt circle with a health-band ring on the attention shelf, a 112 × 136 photo panel in the library directly beneath it, a 56 pt rounded square at `insetRadius` on a care row, and a 52 pt tile at a *computed* `size × 0.32` radius in Ask's scope rail (16.6 pt — beside a "more" tile at 20.5 pt, two radii nobody chose). **Now** `PlantRow` is the one anatomy: a 56 pt thumbnail at `compactRadius`, the name, one status line, one trailing slot. The band ring is gone with the circle — a coloured ring around a photograph repeated, in decoration, what the status line was already saying in words.

**Two facts had six spellings, and shared one colour.** "Check-in overdue", "OVERDUE" in tracked caps, "Urgent · Review plant", "Needs attention", "Health check-in" with a red day label, "Needs care 2" — and *sick* and *late* were both `danger`. On a grove of two plants, one dying and one merely un-photographed, the library printed two identical red lines. **Now** `GroveStatus` carries a tone chosen from what the fact *is*:

| Tone | Means | Colour |
| --- | --- | --- |
| `urgent` | the plant is in trouble | `danger` |
| `attention` | the plant needs a look | `healthAttention` |
| `late` | work Grove owes is overdue | `warning` |
| `due` | work is due today, actionable now | `accentStrong` |
| `quiet` | work is coming, or the plant is paused | `mutedInk` |
| `steady` | nothing owed | `healthHealthy` |

Red therefore means *the plant*, anywhere in Grove; amber means *the calendar*. `GroveStatusLabel` is the one way it is written down — a dot and a sentence, never an SF Symbol that changes per case and has to be decoded before the sentence that says the same thing. The tracked-caps day label is gone, which also returns `GroveEyebrow` to being the app's only uppercase voice (rule 13 of audit five).

**Trailing edges meant four things.** Ask's suggestions used `arrow.up.right` — which means *leaves this place* on every platform, and nothing in Grove leaves — while recent questions and care rows used a chevron, attention rows used a pill, and library rows used nothing. **Now**: `GroveRowChevron` means the row navigates, a control or pill means the row acts in place, and an empty slot means the row is only telling you something. The care row's tick moved from a disc in the gutter *outside* the card to the trailing slot, which also killed the inert green disc beside check-ins that looked like a button that had stopped working.

**Columns of cards became lists.** Care rows, attention rows and Ask's suggestions were each drawn as individually shadowed floating cards, so a five-item list was five objects with five edges. **Now** `GroveRowGroup` + `GroveRowDivider` draw one card with hairlines between rows — the idiom every shipped iOS list uses, and the thing that lets the eye follow one left edge down a column.

**Rows carried more than a row can hold.** A care row had seven elements: gutter disc, thumbnail, name, care kind in accent green, the task's own sentence truncated mid-word ("One fresh photo. Grove lin…"), a tracked-caps day, and a chevron. Two of those said *when*; one said nothing at all once it was clipped. **Now** the kind and the day are one status sentence, and the explaining sentence stays on the task's own page where there is room to finish it.

**Per screen.**

- **Ask** had two controls for one state — the photo rail at the top and a "Whole grove ⌄" capsule above the field. The rail wins (it shows the plants' own faces) and the field now says the scope itself: "Ask Ari about Wild Orange…". Suggestions dropped their provenance subtitles ("Recorded health across your grove") — data provenance offered to someone who has not asked anything yet, at double the row height — and went from two to four, because the reader is scanning for one that fits. Recent questions clamp to two lines instead of one: a single line rendered `Wild Orange, my Wild Orange, is showing as "Ur…`, a sentence cut mid-word in a list whose only job is recognition. The plant's name is stripped from the front when the meta line below already says it. The "Ask about" heading is gone: a 24 pt serif title over a row of the user's own plants was the page's largest type spent on its smallest idea.
- **Today**'s checklist said 67% three ways in one row — a ring, a percentage inside it, and "2 of 3 complete" beside it — and a percentage is the wrong unit for three things you can count. The count keeps the words and `GroveProgressBar` carries the picture, so the checklist stops being the one place with a bespoke gauge. "Find its name, without adding it" became "Point the camera, get a name": defensive copy about what a feature *won't* do, replaced with its outcome.
- **My Grove** showed the same plants twice in the same clothes at two sizes, forty points apart. The library is now a two-up grid of photographs — the shelf is the shortlist you act on, this is the grove you look at, and two registers only work when they look like two different things. Zero-count chips are gone: "Healthy 0" is inventory, not a filter, and it promises a list it cannot produce. `"Unassigned"` stopped leaking out of the scan flow as though it were a room — it was appearing as a browse chip and as a caption under every un-placed plant, and a missing value is silence, not a caption.

## Rules for every future screen

1. **No literal colors in views.** If you're typing `Color(red:` outside `DesignSystem.swift` or `JourneyWorld`, stop and add/reuse a token.
2. **No new radii, shadows, springs, or display sizes.** Pick from the scales. If the scale genuinely can't express the design, change the scale in one place.
3. **Every screen picks a page shape.** Tab root (`groveHeaderBar` + in-content header), editorial page (`groveEditorialPage`), or native context (`grovePageTitle`) — never a bare system `navigationTitle`.
4. **Primary action = ink CTA pill.** `GroveCTAButton` / `GroveCTALabel` (use `onDark` over photos/camera). In-card confirmations = `GroveInkButton`; secondary = `GroveOutlineButton`; the page's committing action sits in `.groveActionBar()`. Never hand-roll a capsule. Native contexts (Forms, alerts, `ContentUnavailableView`) use native controls.
5. **Models stay presentation-free.** Colour for a domain concept is an extension in `DesignSystem.swift`.
6. **Illustration gets a named palette.** Storybook art is welcome — as a governed enum with documented values, never inline. `JourneyWorld` for the map, `Botanical` for the plant portraits.
7. **A plant is drawn, never glyphed.** Where a real `Plant` exists and no photo does, it gets its `PlantPortrait`. `PlantArtwork`'s symbol form is only for a plant Grove genuinely does not have yet.
8. **If you tap a picture of it, it grows out of it.** A destination reached from its own card, tile or row gets `.groveHeroSource(route)` on the source and an entry in `AppRoute.zoomsFromSource`. Everything else keeps the standard push — motion has to mean something.
9. **One component per repeated pattern.** The third time a pattern appears, it becomes a shared component in `Components.swift`.
9a. **A plant in a list is `PlantRow`.** One thumbnail size, one radius, one status line, one trailing slot. Status is always a `GroveStatus` drawn by `GroveStatusLabel` — never a hand-picked colour and a hand-written sentence. A column of them is a `GroveRowGroup`, not a column of cards.
9b. **Red is the plant; amber is the calendar.** `danger` and `healthAttention` say something is wrong with a living thing. `warning` says work is late. They may never be swapped, and a trailing chevron may never mean anything but "this row navigates".
10. **Both appearances, always.** Every token is defined for light and dark; nothing may opt out by hardcoding. The exception is deliberate and named: content on a *fixed*-white surface uses `inkOnLight`, because the camera and photo screens force the dark appearance and adaptive ink would vanish there.
11. **It has to fit a 4.7" screen.** Any screen taller than its container scrolls. A fixed-height composition between a fixed header and a fixed footer is a clipping bug waiting for a small phone; a floating bottom button needs `safeAreaInset`, not an overlay, or it covers the last card.
12. **Modern where it shows, graceful where it doesn't.** The floor is iOS 18. Newer platform materials go behind `if #available`, in a component, with a fallback that is a considered design rather than a stripped one.

Follow these rules and the app cannot drift back apart: unity stops being a matter of taste and becomes a property of the codebase — and rules 6 to 8 are the ones that keep it from being unified into someone else's app.

## 16. One board (Oct 2026)

The Flighty-direction rebuild landed screen by screen and came out as six dialects of one idea: two type voices (SF Pro on the new screens, SF Pro Rounded everywhere else), a green primary pill beside an ink one, night green spent on four unrelated cards, lit edges on some cards and flat hairlines on others, and radii of 10, 14, 18 and 26 that no scale contains. These are the rules that make it one app again. They supersede the Fraunces, bone-canvas and green-pill notes above.

1. **One type voice.** SF Pro, nothing else. `GroveTheme.display` is SF Pro; display steps are `hero` 34, `title` 30, `heading` 26 (bold, tracked in), `section` 20 and `card` 17 (semibold). Tab roots open on a 34pt title; sections are `title3` semibold with one `subheadline` muted line under them.
2. **One label.** Small caps are `caption2` semibold, tracking 0.6. `GroveEyebrow` and `GroveStatCell` labels are the same object.
3. **Small caps over a large value.** Any fact with a number or a date is a `GroveStatCell`. Rows of them stack vertically at accessibility sizes.
4. **One ground.** Every page and every sheet sits on `GroveTheme.background`. Cards are `surface` with a 1pt `separator` hairline (`groveCard()`), flat. `groveEdgeLight` draws the same hairline. Shadows are for things that float: chips, markers, docked bars.
5. **Night green has two jobs.** The Today rooms map, and Ari speaking (`groveAriSurface()`). The Premium paywall is the one full-screen exception. Nothing else is night green.
6. **One primary button.** An ink capsule with the label only (`grovePrimaryPill`, `GroveCTAButton`, onboarding capsules). Green is the colour of a plant doing well, never of a button.
7. **Four radii.** `compactRadius` 12 (thumbnails, tiles), `insetRadius` 16 (nested rows, guide cards), `cardRadius` 22 (cards, including photo cards), `heroRadius` 28 (sheets over a photo). Nothing else. The one exception is a mark, not a container: the tab bar's scan action is a leaf (`GrovePrimaryActionButton.shape`, half-side corners with 8pt tips), the only silhouette in the bar that can only be Grove's.
8. **A plant in a list** is its photo with a status dot and its three-letter code, then label/value columns (`TodayBoardRow`). Red is the plant, amber is the calendar.
9. **One frame: the Flighty board.** Every tab root is `GroveBoardPage`: one full-bleed hero that runs up under the status bar (Today: the rooms map; Ask: Ari's question over the plant's photo; Friends: the live handover or your circle; My Grove: the most improved plant's photo), and a white sheet with a grabber that rises over its bottom edge carrying `GroveTabHeader` (the tab's name at 34pt, one muted fact line) and every section. Heroes are either a plant's own photo (`GrovePhotoHero`) or night green (`GroveNightHero`), with their caption low and left, clear of the sheet. The bar is transparent over the hero with dark-appearance chips. Pushed pages that have a photo (a plant, a scan result, a check-in) use the same photo-and-sheet frame. Nothing is a card in the margins at the top of a tab.

## 17. The Journey is a tree (Oct 2026)

The storybook map (biomes, the gold road, Sprout walking it, keepsakes planted in the scenery) was the last screen still speaking the pre-board language. It is now a board page like every other, and its picture is the one only Grove could draw: a tree's cross-section. This supersedes audit 7's "beautiful foreign country" notes for the map itself; `JourneyWorld` still colours the chest ceremony and the plant portraits.

1. **One frame.** `JourneyMapView` is a `GroveBoardPage` with the root header bar: night-green hero, white sheet, `GroveTabHeader("Journey")` with the level line under it, a rosette chip to Badges.
2. **Each chapter is a growth ring.** The ring being played is always drawn at 64pt so its steps never crowd. Finished chapters pack inward toward the heart, the way old wood does, in the plant-doing-well green; future chapters sit outside as hairlines with their names set along them. The XP total is the pith. Ring colours live in `JourneyWorld` (`ringGrain`, `ringLine`, `ringPith`, `ringLabel`, `ringUntravelled`, `ringSealedChest`); status colours are the map's own (`mapThriving`, `gold`).
3. **A step is a dot, and the dot is the button.** Green filled is done, gold with a halo is a chest to open, a white ring is the next step, hollow is not yet. The drawing is 8 to 14pt; the target is 44pt. Gold still only ever means a reward.
4. **The sheet answers "what now".** Four small-caps stats (level, this chapter, streak, badges), then **Fastest way up**: every chest waiting in an open chapter first (a finished chapter's last chest is only reachable here), then steps one real action finishes today, ranked by XP. A check-in counts as doable only when a plant is due one; Grove never nudges an early photo for points. Then the chapter as a list, then Today's three.
5. **Only lessons and quizzes wait their turn.** A later step whose requirement is a real action (a check-in, logged care, a new plant) completes the moment it happens, so tapping it opens its own page with the way to do it, not a "finish this first" sheet.
6. **Words say chapter; the picture draws rings.** "Chapter 1 of 5", "This chapter". The rings are how a chapter looks, not a second name for it.
7. **One celebration frame.** A finished step, a badge, a chest and a new level all use `JourneyTakeover`: night green, gold as the only light, the object in the middle, facts as `JourneyFactRow`, one light pill docked at the bottom, `.isModal`, no confetti, Reduce Motion respected. `GroveCTALabel(onDark:)` now really resolves the pill in the dark appearance, so a primary button can't vanish into a dark ground again.

## 18. First run's world, carried through (Oct 2026)

Onboarding is drawn: Sprout potted on a windowsill, a room scene per answer, a sky over home. Those drawings are governed by one palette, `SproutWorld` (`Grove/Onboarding/OnboardingSprout.swift`), the way `JourneyWorld` governs the map. They appear outside first run at exactly these points, and nowhere else:

1. **A room has a colour.** Each of the six standard rooms (living room, bedroom, kitchen, bathroom, office, garden) has a glyph and a wash-and-ink pair. `GroveRoomTheme(name:)` maps any room name onto one of them ("Lounge" is the living room, "Balcony" is outdoors), and anything else is a neutral house. `GroveRoomBadge` is the room's mark; `GroveRoomChip` is the room as a choice.
2. **Choosing a room is one control.** First run, Add plant and Edit plant all use `GroveRoomChip`, and Edit plant shows the chosen room's `RoomScene` with Sprout in it.
3. **Rooms are labelled by their badge** in My Grove: the room filter chips and each room's section title.
4. **An empty grove shows the windowsill.** The "no plants yet" states on Today and My Grove use `WindowsillScene` in place of `GroveEmptyArt`, so the grove someone lands in after onboarding still looks like the one they set up.

Sprout is a character in these drawings, never a voice. Only Ari speaks in the first person (VOICE.md).
