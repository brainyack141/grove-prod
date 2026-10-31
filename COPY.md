# Grove Copy Guide

> Status: canonical voice and copy contract
> Last updated: 25 July 2026
> Companions: [`GROVE.md`](GROVE.md) defines what Grove is. [`DESIGN.md`](DESIGN.md) defines how it looks. This file defines how it talks.

Every word in Grove is product. A button label is a design decision, a notification is a retention decision, and an empty state is the difference between a user who adds a second plant and one who deletes the app. Nobody ships copy that contradicts this file.

## The one-line brief

**Grove tells you what your plant needs, in words a friend would use, and gives you the credit when it works.**

## Who we're writing to

Someone who has killed a plant and felt bad about it. They are not lazy and not stupid — they simply could not see the problem in time. They do not want a hobby, a syllabus, or a lecture. They want the plant on their windowsill to still be there next spring.

Write to that person. Never write to "users", "plant parents", or "the plant community".

## Voice: five rules

### 1. Name the plant

The whole product is that Grove knows *your* plant, not plants in general. Copy has to prove it every time.

> ✅ Pesto is due for a photo.
> ❌ 1 plant needs a check-in.

> ✅ Monstera's soil was still damp last time. Feel it before you water.
> ❌ Remember to check soil moisture before watering.

If a string can take a nickname, a species, a number of days, or a specific observed signal — it takes one.

### 2. The user did it, not the app

Grove noticed. The user acted. The user gets the sentence.

> ✅ You caught that early.
> ❌ Grove detected an early decline.

> ✅ You brought Fig back from Needs attention to Healthy.
> ❌ Fig's health score has improved.

Never congratulate the user for using Grove. Congratulate them for looking after a living thing. Strava never thanks you for opening Strava.

### 3. Say the true thing in short words

Grove makes probabilistic calls about a living organism. Hedging language ("may potentially indicate") reads as evasion; false confidence gets plants killed. Plain words carry uncertainty better than long ones.

> ✅ Probably a spider mite. The webbing is the giveaway — but check the undersides before you treat.
> ❌ Analysis suggests a possible arthropod infestation with moderate confidence.

Ban list: leverage, utilise, seamless, effortless, revolutionary, powerful, AI-powered, smart, unlock your potential, journey (in the self-help sense — the Journey feature is a proper noun), we're excited to, oops.

Numbers beat adjectives. "Under a minute" beats "quick". "14 days" beats "regularly".

### 4. Never nag, never guilt

Duolingo's owl works because it is a joke. Grove is not a joke — a guilt notification about a dying plant is genuinely unpleasant. Grove's reminders are invitations to *look*, and looking is always low-effort and always worth it.

> ✅ Two weeks since you last saw Pesto. One photo, about a minute.
> ❌ Don't let Pesto down! 😢 You haven't checked in for 14 days.

A missed check-in is never framed as a failure. A broken streak is never punished, only offered back.

### 5. Check, then act — in the copy too

Grove's founding principle is a *copy* principle. Grove never instructs an irreversible or harmful action from evidence it doesn't have.

- Never "Water Pesto." Always "Feel Pesto's soil — water only if it's dry."
- Never a streak, badge, XP payout, or celebration attached to watering, feeding, or treating.
- Health, toxicity, and safety copy is never playful, never gamified, and never abbreviated for wit.

## Tone by surface

Grove has one voice at three temperatures. Read the room.

| Surface | Temperature | Sounds like |
| --- | --- | --- |
| Onboarding, Journey, streaks, badges, celebrations | Warm, energetic, a little proud | "First roots down." |
| Today, plant profiles, care tasks, check-ins | Calm, specific, useful | "Fig looks steadier than last time. Same again in two weeks." |
| Health warnings, toxicity, diagnosis limits, deletion, privacy | Flat, exact, unhurried | "Grove has not seen this plant's roots. If it keeps declining on this plan, ask someone who can inspect it." |

The colder the surface, the shorter the sentences and the fewer the adjectives. Never joke inside a warning.

## House style

- **Sentence case** everywhere. Title Case only for proper nouns: Grove, Grove Academy, Journey, First Roots, badge and level names.
- **en-GB.** fertilise, organise, colour, defence, metres. Keep species and scientific names as written.
- **Second person.** "You", "your grove". Grove refers to itself as "Grove", not "we", except where a human promise is being made ("We'll remind you before the trial ends").
- **"your grove"** lowercase when it means the user's plants; **"Grove"** capitalised when it means the app. "Your grove is happy" / "Grove will compare the photos". The one exception is **My Grove**, the name of the plants screen — a proper noun, capitalised wherever it labels that destination and lowercase everywhere it appears in a sentence ("add to my grove").
- **Contractions always.** You're, it's, we'll, don't.
- **No exclamation marks** outside celebration moments — and never more than one per screen.
- **Emoji** only in the Journey, streaks, badges, and the onboarding pill grid. Never in health, safety, sync, or settings copy.
- **Em dashes** sparingly, with spaces. Prefer a full stop.
- **Ellipses** only for genuine in-progress states ("Reading your plant…").

## Patterns

### Buttons

Verb + object, in the user's words, describing what they get.

> ✅ Check in on Pesto · Add to my Grove · Turn on reminders · Send invitation
> ❌ Submit · Confirm · Get started · Learn more

Never "Yes"/"No" in a destructive dialog. Name the action: "Remove plant", "Delete local data", "Sign out".

### Empty states

Three lines, always in this order: **what this is → why it's worth having → one button.** Never apologise for emptiness, and never say "No data".

> **No plants yet**
> Scan a plant you own and Grove starts its living record — identity, health, and what to do next.
> [Scan your first plant]

### Errors

Say what happened, then what the user can do. No blame in either direction, no error codes in the sentence.

> ✅ Grove couldn't reach the analysis service. Your photo is saved — try again when you're back online.
> ❌ Error: analysis request failed (503).

### Celebrations

One short line of praise for the *human*, one line of fact, then out of the way.

> **You did it.**
> First check-in logged. Pesto has a baseline now.

### Notifications

Subject-first, plant named, effort stated, no guilt. Body always tells them what looking will involve.

> **How's Pesto doing?**
> Two weeks since the last photo. Takes about a minute.

Water reminders never say water. They say check.

> **Feel Pesto's soil**
> Two knuckles down. Water only if it's dry.

## The words we own

Use these consistently; they are the product's vocabulary.

| Say | Not |
| --- | --- |
| your grove | your collection, your garden (unless outdoors), your library |
| check in / check-in | log, entry, assessment, survey |
| living record | history, log, data |
| plant friend | contact, buddy, connection |
| plant sitting | sharing, delegation, care sharing |
| baseline | initial reading, first score |
| thriving / healthy / keep an eye on it / needs attention / urgent | any other health wording, ever |
| Grove Academy | Learn, lessons tab, course |
| Journey, milestone, badge, Gardener level | quests, tasks, points, tiers |

## The line we never cross

Grove is allowed to be delightful about learning, noticing, and showing up. It is never allowed to be delightful about a plant's health, a diagnosis, a toxicity risk, or a user's data. When those two instincts collide, the plant wins and the copy goes flat.
