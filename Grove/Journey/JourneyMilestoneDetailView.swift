import Accessibility
import SwiftUI

/// The page for a single step. Lessons and quizzes finish here; action and
/// goal steps say what to do, show how far along they already are, and send
/// the player to the place in the app that does it.
struct JourneyMilestoneDetailView: View {
    @Environment(GroveStore.self) private var store
    @Environment(IntentRouter.self) private var intentRouter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let milestone: JourneyMilestone
    /// Called with any milestones awarded so the map can celebrate.
    let onAward: ([JourneyMilestone]) -> Void

    /// The answer picked most recently.
    @State private var quizSelection: Int?
    /// Wrong answers already tried. They stay struck out, so the same one
    /// can't be picked twice.
    @State private var wrongPicks: Set<Int> = []
    /// True once the quiz is answered correctly in this visit, as opposed to
    /// on an earlier one. Brings up the explanation and the Continue button.
    @State private var answeredNow = false
    /// What this visit earned. It is handed to the page once the sheet has
    /// gone, so the celebration plays on the Journey rather than behind the
    /// sheet, and a swipe down delivers it the same as a button.
    @State private var pendingAwards: [JourneyMilestone] = []

    private var isCompleted: Bool {
        store.gardener.completedMilestoneIDs.contains(milestone.id)
    }

    private var resolved: ResolvedMilestone? {
        store.resolvedMilestone(id: milestone.id)
    }

    private var chapter: JourneyChapter? {
        JourneyLibrary.chapters.first { chapter in
            chapter.milestones.contains { $0.id == milestone.id }
        }
    }

    private var badge: Badge? {
        milestone.badgeID.flatMap(JourneyLibrary.badge(id:))
    }

    private var keepsake: Keepsake? {
        milestone.keepsakeID.flatMap(KeepsakeLibrary.keepsake(id:))
    }

    private var eyebrow: String {
        guard let chapter else { return milestone.kind.label }
        return "\(milestone.kind.label) · Chapter \(chapter.number)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    JourneyStepSheetHeader(milestone: milestone, eyebrow: eyebrow)
                    facts
                }
                switch milestone.kind {
                case .lesson: lessonBody
                case .quiz: quizBody
                case .action, .goal: actionBody
                case .chest: chestBody
                }
                if badge != nil || keepsake != nil {
                    rewards
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let action = dockAction {
                GroveCTAButton(title: action.title, action: action.perform)
                    .groveActionBar()
                    .transition(.opacity)
            }
        }
        .groveBackground()
        .groveEditorialPage(chapter?.title ?? milestone.kind.label)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onDisappear(perform: handOffAwards)
    }

    // MARK: - Facts

    /// XP, how far along, and whether it's done, as small caps over values.
    /// "3 of 5" is the difference between a target and a nag.
    private var facts: some View {
        let item = resolved
        var facts: [JourneyFactRow.Fact] = [
            .init(label: "XP", value: "+\(milestone.xpReward)")
        ]
        if milestone.shieldReward > 0 {
            facts.append(.init(
                label: milestone.shieldReward == 1 ? "Shield" : "Shields",
                value: "+\(milestone.shieldReward)"
            ))
        }
        if isCompleted {
            facts.append(.init(label: "Status", value: milestone.isChest ? "Opened" : "Done", tint: GroveTheme.accent))
        } else if let item, item.target > 1 {
            facts.append(.init(label: "Progress", value: "\(min(item.current, item.target)) of \(item.target)"))
        } else if milestone.isChest, item?.status == .ready {
            facts.append(.init(label: "Status", value: "Ready", tint: GroveTheme.goldDeep))
        }

        return VStack(alignment: .leading, spacing: 12) {
            JourneyFactRow(facts: facts)
            // The bar sits under the "3 of 5" it draws, and only when there
            // is one.
            if let item, item.target > 1, !isCompleted {
                GroveProgressBar(fraction: item.fraction, tint: GroveTheme.accent, height: 6, minimumFill: 4)
            }
        }
    }

    // MARK: - Docked action

    private struct DockAction {
        let title: String
        let perform: () -> Void
    }

    /// The sheet's one primary action, if it has one right now.
    private var dockAction: DockAction? {
        switch milestone.kind {
        case .lesson:
            guard !isCompleted else { return nil }
            return DockAction(title: "Mark as read") {
                pendingAwards += store.completeInteractiveMilestone(milestone)
                dismiss()
            }
        case .quiz:
            // Answering is the action. Continue only arrives once the right
            // answer is in, so the explanation stays up until it's been read.
            guard answeredNow else { return nil }
            return DockAction(title: "Continue") { dismiss() }
        case .action, .goal:
            guard !isCompleted, let cta = actionCTA else { return nil }
            return DockAction(title: cta.title) {
                cta.route()
                dismiss()
            }
        case .chest:
            return nil
        }
    }

    private func handOffAwards() {
        guard !pendingAwards.isEmpty else { return }
        let awarded = pendingAwards
        pendingAwards = []
        onAward(awarded)
    }

    // MARK: - Lesson

    @ViewBuilder
    private var lessonBody: some View {
        if let topic = lessonTopic {
            VStack(alignment: .leading, spacing: 20) {
                Text(topic.intro)
                    .font(.body)
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(topic.sections.prefix(2)) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.heading)
                            .font(.headline)
                            .foregroundStyle(GroveTheme.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(section.body)
                            .font(.body)
                            .foregroundStyle(GroveTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                fullLessonRow(topic)
            }
        }
    }

    /// Opens the whole lesson on the stack the Journey sits in. The sheet's own
    /// navigation stack registers no destinations, so a `NavigationLink` here
    /// went nowhere; this is the same hand-off the docked button uses.
    private func fullLessonRow(_ topic: LearnTopic) -> some View {
        Button {
            intentRouter.pushedRoute = AppRoute.learnTopic(topic.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read the full lesson")
                        .font(.body.weight(.medium))
                        .foregroundStyle(GroveTheme.ink)
                    Text("\(topic.title), \(Self.readTime(minutes: topic.readMinutes))")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                GroveRowChevron()
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .groveCard(padding: 16, radius: GroveTheme.insetRadius)
        }
        .buttonStyle(GroveTilePressStyle())
    }

    /// "a 4-minute read", from the lesson's own length.
    private static func readTime(minutes: Int) -> String {
        let article = [8, 11, 18].contains(minutes) || (80...89).contains(minutes) ? "an" : "a"
        return "\(article) \(minutes)-minute read"
    }

    private var lessonTopic: LearnTopic? {
        guard let id = milestone.lessonTopicID else { return nil }
        return LearnLibrary.topic(id: id)
    }

    // MARK: - Quiz

    @ViewBuilder
    private var quizBody: some View {
        if let quiz = milestone.quiz {
            VStack(alignment: .leading, spacing: 14) {
                Text(quiz.prompt)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                VStack(spacing: 8) {
                    ForEach(Array(quiz.options.enumerated()), id: \.offset) { index, option in
                        quizOption(index: index, option: option, quiz: quiz)
                    }
                }

                quizFeedback(quiz)
            }
        }
    }

    /// The right answer shows once it's been found, in this visit or an
    /// earlier one.
    private var answerRevealed: Bool { answeredNow || isCompleted }

    private func quizOption(index: Int, option: String, quiz: JourneyQuiz) -> some View {
        let isCorrect = index == quiz.correctIndex
        let isSelected = quizSelection == index
        let isRuledOut = wrongPicks.contains(index)
        let showsCorrect = answerRevealed && isCorrect
        let stroke: Color = showsCorrect ? GroveTheme.accent : (isSelected ? GroveTheme.ink : GroveTheme.separator)
        let shape = RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)

        return Button {
            answer(index, quiz: quiz)
        } label: {
            HStack(spacing: 12) {
                Text(option)
                    .font(.body)
                    .foregroundStyle(isRuledOut ? GroveTheme.mutedInk : GroveTheme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if showsCorrect {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(GroveTheme.accent)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                } else if isRuledOut {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GroveTheme.mutedInk)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(GroveTheme.surface, in: shape)
            .overlay {
                shape.strokeBorder(stroke, lineWidth: showsCorrect || isSelected ? 1.5 : 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.985, haptics: false))
        .disabled(answerRevealed || isRuledOut)
        .accessibilityLabel(option)
        .accessibilityValue(showsCorrect ? "Correct answer" : (isRuledOut ? "Wrong answer" : ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func quizFeedback(_ quiz: JourneyQuiz) -> some View {
        if answerRevealed {
            VStack(alignment: .leading, spacing: 6) {
                GroveEyebrow(
                    text: answeredNow ? "Correct" : "Why",
                    color: answeredNow ? GroveTheme.accent : GroveTheme.mutedInk
                )
                Text(quiz.explanation)
                    .font(.body)
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .groveCard(padding: 16, radius: GroveTheme.insetRadius)
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        } else if !wrongPicks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                GroveEyebrow(text: "Not quite")
                Text(Self.retryLine)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .transition(.opacity)
        }
    }

    private static let retryLine = "Pick another answer."

    private func answer(_ index: Int, quiz: JourneyQuiz) {
        guard !answerRevealed, !wrongPicks.contains(index) else { return }
        let correct = index == quiz.correctIndex

        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : GroveMotion.snap) {
            quizSelection = index
            if correct {
                answeredNow = true
            } else {
                wrongPicks.insert(index)
            }
        }

        if correct {
            Haptics.success()
            pendingAwards += store.completeInteractiveMilestone(milestone)
            announce("Correct. \(quiz.explanation)")
        } else {
            Haptics.bump()
            announce("Not quite. \(Self.retryLine)")
        }
    }

    /// VoiceOver hears the verdict and the reason, not just a button that went
    /// quiet. High priority so the button's own state change can't talk over it.
    private func announce(_ message: String) {
        var announcement = AttributedString(message)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }

    // MARK: - Action / goal

    @ViewBuilder
    private var actionBody: some View {
        if !isCompleted {
            Text("This step finishes on its own when you do it.")
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Where the player should go to make progress on this node. Every branch
    /// lands somewhere that does real work — none of them just open a tab and
    /// hope.
    private var actionCTA: (title: String, route: () -> Void)? {
        switch milestone.requirement {
        case .plantsOwned, .distinctLocations:
            return ("Add a plant", { intentRouter.startScan(.add) })
        case .checkInsCompleted, .deepestTimeline, .plantReachedBand, .plantsHealthy,
             .plantsThriving, .recoveredPlant, .newGrowthObserved,
             .healthyCheckInRun, .recoveredPlants:
            guard let plant = store.plants.min(by: { $0.nextCheckIn < $1.nextCheckIn }) else {
                return ("Add a plant", { intentRouter.startScan(.add) })
            }
            return ("Check in on \(plant.nickname)", { intentRouter.requestedCheckInPlantID = plant.id })
        case .careLogged:
            return ("Open today's care", { intentRouter.requestedTab = .today })
        case .lessonsLearned:
            // The lessons live in the Academy, so point at the next unfinished
            // one rather than at a tab. `pushedRoute` keeps the user in the
            // stack they are already standing in.
            guard let next = LearnLibrary.all.first(where: { !store.isLessonLearned($0.id) }) else {
                return ("Ask Ari", { intentRouter.requestedTab = .ask })
            }
            return ("Read “\(next.title)”", { intentRouter.pushedRoute = AppRoute.learnTopic(next.id) })
        case .streakReached:
            // Asking about a real plant is the everyday way to tend the streak.
            return ("Ask Ari", { intentRouter.requestedTab = .ask })
        case .collectionsCreated:
            return ("Go to My Grove", { intentRouter.requestedTab = .profile })
        case .sitterInvited, .sitterCareCompleted:
            return ("Set up plant sitting", { intentRouter.requestedRoute = AppRoute.sitting; intentRouter.requestedRouteTab = .profile })
        case .interactive, .chest:
            return nil
        }
    }

    // MARK: - Chest

    /// Chests open from the Journey page, not in a sheet: the ceremony is the
    /// reward. This only ever shows for a chest reached some other way.
    private var chestBody: some View {
        HStack(spacing: 14) {
            ChestArt(milestoneID: milestone.id, unit: 44, lidLift: isCompleted ? 0.4 : 0)
                .accessibilityHidden(true)
            Text(isCompleted
                 ? "Opened. The XP already counts towards your level."
                 : "Open it from the Journey page.")
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groveCard()
    }

    // MARK: - Rewards

    private var rewards: some View {
        VStack(alignment: .leading, spacing: 4) {
            JourneySectionHeader(
                title: isCompleted ? "What you got" : "What you get",
                subtitle: isCompleted ? "Already yours" : "Yours when this step is done"
            )
            JourneyStepRewardList(
                badge: badge,
                badgeEarned: badge.map { store.gardener.unlockedBadgeIDs.contains($0.id) } ?? false,
                keepsake: keepsake,
                keepsakeEarned: keepsake.map { store.gardener.keepsakeIDs.contains($0.id) } ?? false
            )
        }
    }
}
