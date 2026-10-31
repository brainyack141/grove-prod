import SwiftUI

// The Grove Academy curriculum and its lesson screen.
//
// These lessons used to have a tab of their own. They no longer do: nine static
// lessons are about nine days of content, and a tab whose value goes to zero
// inside two weeks is the wrong use of a tab-bar slot in the exact window where
// retention is decided. The Ask tab took the slot.
//
// The lessons themselves stayed, because they were never really a tab feature:
// the Journey map has lesson nodes that route here (`JourneyLibrary`), the
// learning badge ladder counts them, and `GroveStore.completeLearnLesson` pays
// their XP and tends the streak. All of that still works — only the launcher is
// gone.

// MARK: - Content model

/// A single self-contained lesson in the Grove Academy. Content is static and
/// bundled with the app, so lessons work fully offline.
struct LearnTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let palette: PlantPalette
    let readMinutes: Int
    let intro: String
    let sections: [LearnSection]
    /// One-question active-recall check that completes the lesson.
    var quiz: JourneyQuiz?
}

extension LearnTopic {
    /// Authored lesson artwork. The SF Symbol remains useful in compact labels,
    /// but a large hero is an illustration role, not an icon role.
    var heroArtworkName: String {
        switch id {
        case "academy": "LearnAcademyHero"
        case "watering": "LearnWateringHero"
        case "light": "LearnLightHero"
        case "repotting": "LearnRepottingHero"
        case "pests": "LearnPestsHero"
        case "propagation": "LearnPropagationHero"
        case "nutrients": "LearnNutrientsHero"
        case "pruning": "LearnPruningHero"
        case "humidity": "LearnHumidityHero"
        default: "LearnAcademyHero"
        }
    }
}

struct LearnSection: Identifiable, Hashable {
    let id = UUID()
    let heading: String
    let body: String
    /// Optional "check first" callout, echoing Grove's check-then-act principle.
    var checkFirst: String?
}

// MARK: - Curriculum

enum LearnLibrary {
    /// XP awarded the first time a lesson's quick check is passed.
    static let lessonXP = 15
    /// XP awarded once per day for passing the daily refresher after the
    /// course is complete — keeps higher gardener ranks reachable.
    static let refresherXP = 10

    static let featured = LearnTopic(
        id: "academy",
        title: "Grove Academy",
        subtitle: "Why the rules work, not just what they are",
        symbol: "graduationcap.fill",
        palette: .fern,
        readMinutes: 2,
        intro: "Nine short lessons that turn plant care from folklore into something you can reason about. Start here.",
        sections: [
            LearnSection(
                heading: "Check, then act",
                body: "Great plant care is observation first. Before you water, feed, or move a plant, look at the soil, leaves, and light. Inspect, decide, then do, and note what you saw so trends become visible over time."
            ),
            LearnSection(
                heading: "Progress over perfection",
                body: "No single check-in tells the full story. What matters is the direction of travel: is your plant trending healthier week to week? Regular photo check-ins turn guesswork into a history you can trust."
            )
        ],
        quiz: JourneyQuiz(
            prompt: "A plant looks a little off. What's the Grove way to respond?",
            options: [
                "Water it right away, just in case",
                "Look closely at the soil, leaves, and light first",
                "Move it to a sunnier window immediately"
            ],
            correctIndex: 1,
            explanation: "Check, then act. Observing before intervening prevents the most common mistake in plant care: fixing a problem the plant doesn't have."
        )
    )

    static let topics: [LearnTopic] = [
        LearnTopic(
            id: "watering",
            title: "Watering Wisdom",
            subtitle: "Read the soil, not the calendar",
            symbol: "drop.fill",
            palette: .fern,
            readMinutes: 4,
            intro: "Overwatering kills more houseplants than drought does. The fix is unglamorous: let the soil decide, never the calendar.",
            sections: [
                LearnSection(
                    heading: "The finger test",
                    body: "Push a finger two knuckles into the soil. If it comes out dry, most tropical plants are ready for water. If it's still damp, wait. Roots sitting in wet soil can't breathe and start to rot.",
                    checkFirst: "Inspect the soil before every watering. A calendar can't feel moisture."
                ),
                LearnSection(
                    heading: "Water thoroughly, then drain",
                    body: "When you do water, water until it runs from the drainage holes, then let it drain fully. Shallow sips leave the lower roots thirsty and encourage weak, surface-level growth."
                ),
                LearnSection(
                    heading: "Signs you're getting it wrong",
                    body: "Yellowing lower leaves and a musty smell often mean too much water. Crispy brown edges and drooping usually mean too little. When in doubt, underwater slightly. Most plants recover from thirst faster than from rot."
                )
            ],
            quiz: JourneyQuiz(
                prompt: "The finger test comes back damp two days after watering. What now?",
                options: [
                    "Water a little, to keep it topped up",
                    "Wait and check again in a couple of days",
                    "Mist the leaves instead of watering"
                ],
                correctIndex: 1,
                explanation: "Damp soil means the roots have all they need. Watering again now is how root rot starts. Re-check in a few days."
            )
        ),
        LearnTopic(
            id: "light",
            title: "Light & Placement",
            subtitle: "Match the plant to the window",
            symbol: "sun.max.fill",
            palette: .lime,
            readMinutes: 5,
            intro: "Light is food. Moving a plant two metres solves more problems than any fertiliser ever will.",
            sections: [
                LearnSection(
                    heading: "Know your exposures",
                    body: "South-facing windows give the most intense light; north-facing the least. East windows offer gentle morning sun, west windows harsher afternoon sun. Most 'low-light' plants still want a bright spot out of direct rays."
                ),
                LearnSection(
                    heading: "Watch the plant, not the label",
                    body: "Leaning toward the window, pale new growth, and long gaps between leaves mean not enough light. Bleached or scorched patches mean too much. Rotate a quarter turn each week so growth stays even.",
                    checkFirst: "Before moving a struggling plant, note how far it sits from the nearest window."
                )
            ],
            quiz: JourneyQuiz(
                prompt: "New growth is pale and the stems stretch toward the window. The plant is telling you…",
                options: [
                    "It's getting too much direct sun",
                    "It isn't getting enough light",
                    "It needs fertiliser"
                ],
                correctIndex: 1,
                explanation: "Leaning, pale new growth, and leggy stems are the classic signs of light hunger. Move it closer to a brighter window before reaching for food."
            )
        ),
        LearnTopic(
            id: "repotting",
            title: "Repotting",
            subtitle: "When to size up, and by how much",
            symbol: "arrow.up.bin.fill",
            palette: .sage,
            readMinutes: 4,
            intro: "Fresh soil and room to grow, at the right moment. At the wrong moment it sets a plant back months.",
            sections: [
                LearnSection(
                    heading: "When to repot",
                    body: "Roots circling the bottom, water running straight through, or a plant that dries out within a day are all signs it's time. Spring and early summer, when the plant is actively growing, are ideal."
                ),
                LearnSection(
                    heading: "Only go up one size",
                    body: "Choose a pot just 2–5 cm wider. Too much fresh soil holds water the small root ball can't use, inviting rot. Loosen circling roots gently and settle the plant at the same depth it grew before."
                )
            ],
            quiz: JourneyQuiz(
                prompt: "Time to size up. How much wider should the new pot be?",
                options: [
                    "Just 2–5 cm wider",
                    "At least double the width, to last for years",
                    "Same size, with fresh soil"
                ],
                correctIndex: 0,
                explanation: "A slightly larger pot keeps moisture in balance. A big jump leaves wet soil the roots can't reach, which invites rot."
            )
        ),
        LearnTopic(
            id: "pests",
            title: "Pests & Disease",
            subtitle: "Catch them in week one",
            symbol: "ladybug.fill",
            palette: .sunset,
            readMinutes: 6,
            intro: "Caught early, most pests are a nuisance. Left alone, they take the shelf. A weekly look under the leaves is the whole defence.",
            sections: [
                LearnSection(
                    heading: "Know the usual suspects",
                    body: "Fine webbing hints at spider mites. White cottony tufts are mealybugs. Tiny flies around the soil are fungus gnats, usually a sign of overwatering. Sticky residue on leaves points to sap-sucking insects nearby."
                ),
                LearnSection(
                    heading: "Isolate, then treat",
                    body: "Move an affected plant away from the others immediately. Wipe leaves with diluted insecticidal soap or neem oil, top and underside, and repeat every few days until clear.",
                    checkFirst: "Inspect the undersides of leaves. That's where infestations start and hide."
                )
            ],
            quiz: JourneyQuiz(
                prompt: "You spot fine webbing on the undersides of the leaves. The likely culprit is…",
                options: [
                    "Fungus gnats",
                    "Mealybugs",
                    "Spider mites"
                ],
                correctIndex: 2,
                explanation: "Fine webbing is the spider mite signature. Isolate the plant and wipe both sides of the leaves with insecticidal soap or neem oil."
            )
        ),
        LearnTopic(
            id: "propagation",
            title: "Propagation",
            subtitle: "One plant, then several, for free",
            symbol: "leaf.arrow.triangle.circlepath",
            palette: .moss,
            readMinutes: 5,
            intro: "The most satisfying thing you can do with a pair of scissors, and far easier than it looks.",
            sections: [
                LearnSection(
                    heading: "Take a good cutting",
                    body: "For most trailing and upright plants, cut just below a node, the little bump where leaves and roots emerge. Include a few leaves, and remove any that would sit underwater."
                ),
                LearnSection(
                    heading: "Root in water, then pot",
                    body: "Place the cutting in water in a bright, indirect spot and refresh it weekly. Once roots reach a few centimetres, pot into moist soil and keep it a little more humid while it settles in."
                )
            ],
            quiz: JourneyQuiz(
                prompt: "Where should you cut to give a cutting the best chance of rooting?",
                options: [
                    "Just below a node",
                    "Halfway along a healthy leaf",
                    "Anywhere: plants root from any cut"
                ],
                correctIndex: 0,
                explanation: "Nodes are where roots emerge. Cutting just below one gives your cutting its root-growing machinery."
            )
        ),
        LearnTopic(
            id: "nutrients",
            title: "Soil & Nutrients",
            subtitle: "What the roots are sitting in",
            symbol: "aqi.medium",
            palette: .fern,
            readMinutes: 4,
            intro: "Roots need air as much as water. What is in the pot matters more than what you pour into it.",
            sections: [
                LearnSection(
                    heading: "Match the mix to the plant",
                    body: "Most houseplants want a mix that drains freely, so add perlite or bark to standard potting soil. Succulents and cacti need grittier blends; ferns and calatheas prefer something that holds a little more moisture."
                ),
                LearnSection(
                    heading: "Feed lightly, in season",
                    body: "Fertilise during active growth in spring and summer, at half the label's strength. Pause in winter when growth slows. More food is not more growth. Excess salts build up and burn roots.",
                    checkFirst: "Check that soil is already moist before feeding; fertiliser on dry roots can scorch them."
                )
            ],
            quiz: JourneyQuiz(
                prompt: "What's the safest way to fertilise a houseplant?",
                options: [
                    "Full strength, weekly, all year round",
                    "Half strength, during spring and summer growth",
                    "Only in winter, when the plant is resting"
                ],
                correctIndex: 1,
                explanation: "Feed lightly while the plant is actively growing and pause in winter. Excess fertiliser builds up as salts that burn roots."
            )
        ),
        LearnTopic(
            id: "pruning",
            title: "Pruning",
            subtitle: "Cut less, and cut better",
            symbol: "scissors",
            palette: .lime,
            readMinutes: 3,
            intro: "Every cut is a decision about where the plant spends its energy next. Make it deliberately.",
            sections: [
                LearnSection(
                    heading: "Remove the three D's",
                    body: "Start with anything dead, damaged, or diseased. Use clean, sharp scissors and cut just above a node so new growth emerges in the direction you want."
                ),
                LearnSection(
                    heading: "Pinch to bush out",
                    body: "Pinching off the growing tip of leggy stems encourages the plant to branch, giving you a fuller, more compact shape over time."
                )
            ],
            quiz: JourneyQuiz(
                prompt: "You're pruning a plant. What goes first?",
                options: [
                    "The longest healthy stems",
                    "Anything dead, damaged, or diseased",
                    "All the new growth tips"
                ],
                correctIndex: 1,
                explanation: "The three D's (dead, damaged, diseased) always go first. They cost the plant energy and can spread problems."
            )
        ),
        LearnTopic(
            id: "humidity",
            title: "Humidity & Air",
            subtitle: "The stressor nobody checks",
            symbol: "humidity.fill",
            palette: .sage,
            readMinutes: 3,
            intro: "Most popular houseplants came from humid forest floors. Your flat in February is nothing like that.",
            sections: [
                LearnSection(
                    heading: "Read the leaf tips",
                    body: "Persistent crispy brown tips on otherwise healthy plants often signal air that's too dry rather than a watering problem. Tropical foliage plants feel it first."
                ),
                LearnSection(
                    heading: "Raise humidity the reliable way",
                    body: "Grouping plants together, a pebble-and-water tray, or a small humidifier all help. Misting looks nice but its effect fades within minutes. Treat it as a bonus, not a solution."
                )
            ],
            quiz: JourneyQuiz(
                prompt: "A well-watered tropical plant keeps getting crispy brown leaf tips. The most likely cause is…",
                options: [
                    "The air is too dry",
                    "It needs more fertiliser",
                    "The pot is too small"
                ],
                correctIndex: 0,
                explanation: "Crispy tips on an otherwise healthy, well-watered tropical usually mean dry air. Group plants together or add a humidifier. Misting alone fades in minutes."
            )
        )
    ]

    /// Every lesson, foundations first. Drives course progress.
    static let all: [LearnTopic] = [featured] + topics

    static func topic(id: String) -> LearnTopic? {
        all.first { $0.id == id }
    }
}

// MARK: - Lesson page: the board

// A lesson reads like every other page in Grove that has a picture (DESIGN.md
// §16 rule 9): the painted artwork runs up under the status bar, and a white
// sheet with a grabber rides over its bottom edge carrying everything else.
// The sheet opens on the title and three facts in small caps, gives the short
// version in one large line, then numbers the parts down a single left edge.
// One question at the end is what marks the lesson learned.

struct LearnTopicDetailView: View {
    let topicID: String

    @Environment(GroveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Payout from finishing the lesson this visit; drives the reward card.
    @State private var reward: GroveStore.LearnReward?
    @State private var collapsed = false

    private var topic: LearnTopic? { LearnLibrary.topic(id: topicID) }

    var body: some View {
        Group {
            if let topic {
                page(for: topic)
            } else {
                GroveEmptyState(
                    scene: .vanished,
                    title: "That lesson has moved",
                    message: "It is no longer part of the course."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .groveBackground()
                .groveEditorialPage("Guide")
            }
        }
    }

    private func page(for topic: LearnTopic) -> some View {
        let isLearned = store.isLessonLearned(topic.id)
        let position = LearnLibrary.all.firstIndex { $0.id == topic.id } ?? 0

        // Same construction as the plant page: the chrome is a sibling of the
        // scroll view, so the artwork starts at the physical top of the screen
        // while the back chip still lands under the status bar.
        return ZStack(alignment: .top) {
            LessonSheetFrame(collapsed: $collapsed) {
                hero(for: topic, position: position)
            } sheet: {
                titleBlock(for: topic, isLearned: isLearned)

                shortVersion(topic.intro)

                LessonParts(sections: topic.sections)

                ending(for: topic, isLearned: isLearned)

                if let next = nextTopic(after: position) {
                    LessonNextRow(topic: next, isLearned: store.isLessonLearned(next.id))
                }
            }

            LessonChrome(title: topic.title, collapsed: collapsed) { dismiss() }
        }
        .background(GroveTheme.surface.ignoresSafeArea())
        .groveStatusBar(collapsed ? .darkContent : .lightContent)
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.inline)
        // The page draws its own chrome, for the reason PlantDetailView gives:
        // iOS 26 bar items come out as pale glass discs over a dark hero.
        .groveHidesNavigationBar()
    }

    // MARK: Hero

    private func hero(for topic: LearnTopic, position: Int) -> some View {
        // The artwork is 2:1, so filling a 340pt height would make it ~680pt
        // wide and drag the whole page past the screen edges. A fixed-size
        // clear frame decides the bounds; the painting only fills them.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 340)
            .overlay {
                Image(topic.heroArtworkName)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            }
            .clipped()
            .overlay { LessonScrim() }
            .overlay(alignment: .bottomLeading) {
                LessonCaps(
                    position == 0 ? "Grove Academy · Start here" : "Grove Academy · Lesson \(position + 1) of \(LearnLibrary.all.count)",
                    color: .white.opacity(0.85)
                )
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.bottom, LessonSheetFrame<EmptyView, EmptyView>.overlap + 16)
            }
            .accessibilityHidden(true)
    }

    // MARK: Sheet

    private func titleBlock(for topic: LearnTopic, isLearned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(topic.title)
                    .font(GroveTheme.display(GroveDisplayStyle.hero.points))
                    .tracking(-0.4)
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(topic.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle().fill(GroveTheme.separator).frame(height: 1)

            HStack(alignment: .top, spacing: 12) {
                GroveStatCell(label: "Read", value: "\(topic.readMinutes) min", large: true)
                GroveStatCell(label: "Parts", value: "\(topic.sections.count)", large: true)
                if isLearned {
                    GroveStatCell(label: "Status", value: "Learned", tint: GroveTheme.accentStrong, large: true)
                } else {
                    GroveStatCell(label: "Worth", value: "+\(LearnLibrary.lessonXP) XP", large: true)
                }
            }
        }
    }

    private func shortVersion(_ intro: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LessonCaps("The short version", color: GroveTheme.accentStrong)
            Text(intro)
                .font(.title3.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func ending(for topic: LearnTopic, isLearned: Bool) -> some View {
        if let reward {
            LessonRewardCard(reward: reward, streak: store.displayStreak)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        } else if let quiz = topic.quiz {
            LessonQuestion(quiz: quiz, isLearned: isLearned) {
                completeLesson(topic)
            }
        } else if !isLearned {
            GroveInkButton(title: "Mark as learned", systemImage: "checkmark") {
                completeLesson(topic)
            }
        }
    }

    private func nextTopic(after position: Int) -> LearnTopic? {
        let next = position + 1
        return LearnLibrary.all.indices.contains(next) ? LearnLibrary.all[next] : nil
    }

    private func completeLesson(_ topic: LearnTopic) {
        guard let earned = store.completeLearnLesson(topic.id) else { return }
        // Finishing a lesson awards XP and can unlock a badge, so it gets the
        // rising celebration rather than a flat success notification.
        Haptics.celebrate()
        withAnimation(GroveMotion.celebrate) {
            reward = earned
        }
    }
}

// MARK: - The parts

/// The lesson body: numbered parts down one left edge, hairlines between them.
/// The number column is the same width all the way down so the headings line
/// up like a contents page.
private struct LessonParts: View {
    let sections: [LearnSection]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                LessonPart(index: index, section: section)
                    .padding(.vertical, 22)
                if index < sections.count - 1 {
                    Rectangle()
                        .fill(GroveTheme.separator)
                        .frame(height: 1)
                        .padding(.leading, LessonPart.numberColumn)
                }
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(GroveTheme.separator).frame(height: 1)
        }
    }
}

private struct LessonPart: View {
    static let numberColumn: CGFloat = 38

    let index: Int
    let section: LearnSection

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(String(format: "%02d", index + 1))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(GroveTheme.subtleInk)
                .frame(width: Self.numberColumn, alignment: .leading)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(section.heading)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                Text(section.body)
                    .font(.body)
                    .foregroundStyle(GroveTheme.ink.opacity(0.86))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let checkFirst = section.checkFirst {
                    LessonCheckFirst(text: checkFirst)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Grove's check-then-act rule, said where it applies. A quiet inset rather
/// than a callout: it is part of the advice, not an alert about it.
private struct LessonCheckFirst: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LessonCaps("Check first", color: GroveTheme.accentStrong)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GroveTheme.secondarySurface, in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One question

/// One question at the end of the lesson. Passing it is what marks the lesson
/// learned, so completion means recall, not scrolling.
private struct LessonQuestion: View {
    let quiz: JourneyQuiz
    let isLearned: Bool
    let onPass: () -> Void

    @State private var selection: Int?

    private var answeredRight: Bool { selection == quiz.correctIndex }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("One question")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(isLearned ? "You've passed this one. Try it again any time." : "Get it right to finish the lesson.")
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
            }

            Text(quiz.prompt)
                .font(.headline)
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            VStack(spacing: 0) {
                ForEach(Array(quiz.options.enumerated()), id: \.offset) { index, option in
                    optionRow(index: index, option: option)
                    if index < quiz.options.count - 1 {
                        Rectangle()
                            .fill(GroveTheme.separator)
                            .frame(height: 1)
                            .padding(.leading, 52)
                    }
                }
            }
            .groveCard(padding: 0)

            if let selection {
                VStack(alignment: .leading, spacing: 5) {
                    LessonCaps(
                        selection == quiz.correctIndex ? "That's it" : "Not quite",
                        color: selection == quiz.correctIndex ? GroveTheme.accentStrong : GroveTheme.warning
                    )
                    Text(selection == quiz.correctIndex
                         ? quiz.explanation
                         : "Have another look at the parts above, then pick again.")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func optionRow(index: Int, option: String) -> some View {
        let isCorrect = index == quiz.correctIndex
        let isChosen = selection == index
        let showsRight = answeredRight && isCorrect
        let showsWrong = isChosen && !isCorrect
        let letter = String(UnicodeScalar(UInt8(65 + index)))

        return Button {
            guard !answeredRight else { return }
            // Right and wrong are the two outcomes the question exists to tell
            // apart, so they feel different: a rising celebration, or one soft
            // nudge that reads as "not that one" rather than as failure.
            if isCorrect { Haptics.celebrate() } else { Haptics.bump() }
            withAnimation(GroveMotion.pop) { selection = index }
            if isCorrect { onPass() }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(showsRight ? GroveTheme.accent : (showsWrong ? GroveTheme.warning : GroveTheme.secondarySurface))
                    if showsRight || showsWrong {
                        Image(systemName: showsRight ? "checkmark" : "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(GroveTheme.onAccent)
                    } else {
                        Text(letter)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(GroveTheme.mutedInk)
                    }
                }
                .frame(width: 26, height: 26)

                Text(option)
                    .font(.body)
                    .foregroundStyle(GroveTheme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
            .opacity(answeredRight && !isCorrect ? 0.45 : 1)
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.99, haptics: false))
        .accessibilityLabel(option)
        .accessibilityValue(showsRight ? "Correct" : (showsWrong ? "Not correct" : ""))
    }
}

// MARK: - Reward

/// The beat after the right answer: what it was worth, the streak it kept,
/// any badge it unlocked. Calm, flat, on the same card as everything else.
private struct LessonRewardCard: View {
    let reward: GroveStore.LearnReward
    let streak: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                SproutMascot(expression: .cheer, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lesson learned")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink)
                    Text("Come back tomorrow and the streak keeps going.")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Rectangle().fill(GroveTheme.separator).frame(height: 1)

            HStack(alignment: .top, spacing: 12) {
                GroveStatCell(label: "Earned", value: "+\(reward.xp) XP", tint: GroveTheme.goldDeep, large: true)
                if streak > 0 {
                    GroveStatCell(label: "Streak", value: streak == 1 ? "1 day" : "\(streak) days", tint: GroveTheme.streak, large: true)
                }
            }

            ForEach(reward.achievements) { badge in
                HStack(spacing: 12) {
                    Image(systemName: badge.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(
                            LinearGradient(colors: badge.palette.colors, startPoint: .top, endPoint: .bottom),
                            in: Circle()
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        LessonCaps("New badge", color: GroveTheme.goldDeep)
                        Text("\(badge.title): \(badge.blurb)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GroveTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .groveCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var text = "Lesson learned. \(reward.xp) XP."
        if streak > 0 { text += " \(streak)-day streak." }
        for badge in reward.achievements {
            text += " New badge: \(badge.title)."
        }
        return text
    }
}

// MARK: - Next lesson

/// The way on. A plain row, so the page ends on the next thing to read
/// rather than on a dead end.
private struct LessonNextRow: View {
    let topic: LearnTopic
    let isLearned: Bool

    var body: some View {
        NavigationLink(value: AppRoute.learnTopic(topic.id)) {
            HStack(spacing: 14) {
                Image(topic.heroArtworkName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    LessonCaps(isLearned ? "Next · Learned" : "Next · \(topic.readMinutes) min")
                    Text(topic.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink)
                    Text(topic.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                GroveRowChevron()
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.99))
        .groveCard(padding: 0)
        .accessibilityLabel("Next lesson: \(topic.title)")
    }
}

// MARK: - Frame and chrome

/// The photo-and-sheet frame (DESIGN.md §16 rule 9), as the plant page draws
/// it: a hero under the status bar and a white sheet with a grabber over it.
private struct LessonSheetFrame<Hero: View, Sheet: View>: View {
    @Binding var collapsed: Bool
    @ViewBuilder var hero: Hero
    @ViewBuilder var sheet: Sheet

    @State private var heroHeight: CGFloat = 340
    static var overlap: CGFloat { GroveTheme.heroRadius + 6 }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                    .frame(maxWidth: .infinity)
                    .background(GroveTheme.mapGround)
                    .overlay(alignment: .top) {
                        LinearGradient(colors: [.black.opacity(0.42), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 130)
                            .allowsHitTesting(false)
                    }
                    .clipped()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heroHeight = $0 }
                    .visualEffect { content, proxy in
                        let minY = proxy.frame(in: .scrollView).minY
                        return content.offset(y: minY < 0 ? -minY * 0.66 : 0)
                    }

                VStack(alignment: .leading, spacing: GroveTheme.sectionSpacing) {
                    sheet
                }
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, 26)
                .padding(.bottom, GroveTheme.pageBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .top) {
                    Capsule()
                        .fill(GroveTheme.separator)
                        .frame(width: 38, height: 5)
                        .padding(.top, 8)
                        .accessibilityHidden(true)
                }
                .background(
                    GroveTheme.surface,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: Self.overlap,
                        topTrailingRadius: Self.overlap,
                        style: .continuous
                    )
                )
                .padding(.top, -Self.overlap)
                .zIndex(1)
            }
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y > heroHeight - Self.overlap - 110
        } action: { _, atTop in
            guard atTop != collapsed else { return }
            withAnimation(.easeInOut(duration: 0.22)) { collapsed = atTop }
        }
        .background {
            VStack(spacing: 0) {
                GroveTheme.mapGround.frame(height: 420)
                GroveTheme.surface
            }
            .ignoresSafeArea()
        }
    }
}

/// Back chip over the artwork; once the sheet reaches the top it gains a
/// ground and the lesson's title, like the plant page's chrome.
private struct LessonChrome: View {
    let title: String
    let collapsed: Bool
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(collapsed ? AnyShapeStyle(GroveTheme.ink) : AnyShapeStyle(Color.white))
                    .frame(width: 44, height: 44)
                    .background {
                        Circle().fill(collapsed ? AnyShapeStyle(GroveTheme.surface) : AnyShapeStyle(Color.black.opacity(0.35)))
                    }
                    .overlay {
                        Circle().stroke(
                            collapsed ? AnyShapeStyle(GroveTheme.separator) : AnyShapeStyle(Color.white.opacity(0.28)),
                            lineWidth: 1
                        )
                    }
            }
            .buttonStyle(GroveTilePressStyle())
            .accessibilityLabel("Back")

            Spacer(minLength: 8)

            GroveHeaderTitle(text: title)
                .opacity(collapsed ? 1 : 0)
                .accessibilityHidden(!collapsed)

            Spacer(minLength: 8)

            // Balances the back chip so the title sits on the centre line.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, GroveTheme.pagePadding)
        .frame(height: 44)
        .background(alignment: .top) {
            GroveTheme.surface
                .overlay(alignment: .bottom) {
                    Rectangle().fill(GroveTheme.separator).frame(height: 1)
                }
                .padding(.bottom, -6)
                .opacity(collapsed ? 1 : 0)
                .ignoresSafeArea(edges: .top)
        }
    }
}

/// The scrim that keeps white type legible on the bottom of the artwork.
private struct LessonScrim: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0), location: 0.4),
                .init(color: .black.opacity(0.68), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

/// Small caps, the one label (§16 rule 2).
private struct LessonCaps: View {
    let text: String
    var color: Color = GroveTheme.subtleInk

    init(_ text: String, color: Color = GroveTheme.subtleInk) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

#Preview("Lesson") {
    NavigationStack { LearnTopicDetailView(topicID: "watering") }
        .environment(GroveStore())
}
