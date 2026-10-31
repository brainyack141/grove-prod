# Grove voice

How Grove talks. Every user-facing string in the app follows this file. When a
line and this file disagree, rewrite the line.

## The voice

Grove is the good person at the garden centre: knows plants cold, says things
simply, never performs. Three attributes, fixed everywhere:

- **Calm.** No urgency theatre, no exclamation marks outside a genuine
  celebration, no drama in errors.
- **Concrete.** Real nouns (leaf, soil, pot, window, water), plain verbs. Say
  the thing, not the idea of the thing.
- **Quietly warm.** Warmth comes from paying attention ("Monty's soil is dry
  two knuckles down"), not from adjectives or pep.

British/NZ English throughout: colour, come round, fortnight.

## Hard rules

1. **No em dashes.** Not in any user-facing string. Use a comma, a full stop,
   or restructure the sentence. (Code comments are exempt.)
2. **Grove never watches, sees, thinks, or says.** The app is not a character.
   State what happens instead: not "Grove is watching the dates" but "You'll
   get a reminder when something's due." "We" is allowed sparingly for the
   humans behind the app (support, promises, apologies). Ari, Grove's botanist,
   is the single exception, and only inside Ask: see below.
3. **No aphorisms.** A string states its content and stops. If a line would
   look at home on a poster, cut the flourish. Ban the fragment-payoff cadence
   ("One scan. That's all it takes.") and the "One X starts Y" construction.
4. **Outcome, not mechanism.** Users get what a control does for them, never
   how the system achieves it. Exception: destructive and data-safety copy
   (deletion, export), where precision is the kindness.
5. **One idea per string.** If a sentence needs "so" or "which means", it is
   usually two strings or one too many.
6. **Buttons are verb + object.** "Add plant", "Take the photo", "Sign out".
   Titles are noun phrases, not koans.
7. **Numbers beat adjectives.** "3 plants need water" beats "A few plants are
   thirsty."

## Vocabulary: one term per concept

| Concept | The word | Never |
|---|---|---|
| Daily attention habit | streak | run, looking streak |
| Missed-day protection | shield | banked, held, covered, caught |
| Looking at a plant and logging it | check-in / check in on | a look, a proper look, looking |
| AI identification | scan | reading |
| AI health assessment | diagnosis | reading, verdict |
| The user's collection | your grove | your record, the record |
| The Ask feature's answerer | Ari | the botanist, coach, plant reader |

"Check in" is the verb, "check-in" is the noun. A streak is measured in days
and it is "saved" by a shield, nothing else.

## Tone map

| Surface | Dial | Notes |
|---|---|---|
| Errors, offline, limits | Plain, zero personality | What happened + what to do next. Two sentences max. |
| Settings, legal, data | Literal and boring on purpose | Precision over charm. |
| Empty states | Plain + one warm beat | Name the action that fills the screen. |
| Today masthead | Warm, short | Greeting may be human; subtitle states the day's facts. |
| Onboarding questions | Human, first person | The existing answer chips ("I've killed a few") are the register. |
| Paywall | Honest, specific | List what Premium does. No pressure copy. |
| Celebrations | The one place craft is spent | See below. |

## The three earned moments

Personality may spike in exactly three places. Everywhere else stays plain.

1. **First plant added.**
2. **A streak milestone.**
3. **A diagnosed plant confirmed recovering.**

Even here: concrete beats clever. "Monty looks better than last week" is the
ceiling, not "Your grove grows greener by the day."

## Ari

Ari is the one named character in the product. Grove narrates; Ari talks. That
licence covers Ask and nothing else: no other screen may speak in first person.

Who they are: the person at the good garden centre who has been doing this for
thirty years. Not a chatbot with a plant hat on. Four traits, and every one of
them is also a product argument:

1. **Notices before advising.** Opens on what the record actually shows ("Soil
   was still wet at Tuesday's check-in"), then says what to do. This is the
   whole reason someone asks Grove rather than a search box.
2. **Has an opinion.** "I'd leave it another week", not "you could consider
   waiting." Decisive about the action even while honest that the cause is
   unconfirmed.
3. **Under-reacts.** Most houseplant worry is bigger than the problem. Saying
   "that's normal" and stopping is the answer, not a preamble to one.
4. **Says when it can't tell.** A text conversation cannot diagnose. "I can't
   tell from here, can you check X?" is a real answer and it protects the plant.

Warmth is attention, never adjectives. Use the plant's name. One dry human line
is allowed at the very end when the news is good, one sentence, never a joke at
the user's expense.

Banned outright: opening praise ("Great question"), sign-offs ("Hope this
helps", "Happy growing"), exclamation marks, emoji, calling itself an AI or a
model, narrating its own process, and lecturing someone who already did the
right thing.

Always call the character "Ari". "Botanist" is Ari's role, while "Ask" is the
feature and destination.

Enforced in three places, all of which must agree: the system prompt in
`supabase/functions/_shared/botanist-core.mjs`, the reviewer prompt beside
it (a revision must not flatten the voice), and the voice checks in
`Backend/eval/botanist-eval.mjs`.

## The two tests

Before a string ships:

1. **Read it aloud.** Would a smart friend text this? If it sounds recited,
   rewrite it.
2. **Outcome test.** Does it tell the user something they can act on or feel,
   rather than how the feature was designed?
