import PhotosUI
import SwiftUI
import UIKit

// MARK: - Ask tab

/// The botanist coach: a plant expert that has already read the user's grove.
///
/// The root is a launcher, but a launcher built around a real composer. An
/// earlier pass had no field on this screen at all: typing your own question
/// meant finding a floating "New chat" button and waiting for a second screen to
/// push. The suggestions stay, grounded in the user's own plants so nobody has
/// to invent a question from nothing, but they now fill the field instead of
/// bypassing it, and the field is where the tab starts.
struct AskView: View {
    @Environment(GroveStore.self) private var store
    @Environment(AskSession.self) private var ask
    @Environment(GrovePremiumStore.self) private var premium
    @Environment(IntentRouter.self) private var intentRouter

    /// nil scopes the conversation to the whole grove.
    @State private var scopedPlantID: UUID?
    @State private var paywallReason: AskPaywallSheet.Reason?
    @State private var isShowingScopePicker = false
    @State private var isShowingHistory = false
    @State private var historyThreadToOpen: UUID?
    @State private var isShowingCamera = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoDraft: BotanistPhotoDraft?
    @State private var photoError: String?
    @State private var isLoadingPhoto = false
    /// The question being typed, before it has a conversation to live in.
    @State private var draft = ""
    @State private var showsAIConsent = false
    @State private var pendingAIConsent: PendingAIConsent?
    @State private var didAgreeToAIConsent = false

    private enum PendingAIConsent {
        case draft
        case prompt(AskPrompt)
    }

    @FocusState private var isComposerFocused: Bool

    private var scopedPlant: Plant? {
        scopedPlantID.flatMap { id in store.plants.first { $0.id == id } }
    }

    /// Everything worth asking about the current scope, priority-ordered. The
    /// full pool is available in the starter rail.
    private var suggestionPool: [AskPrompt] {
        let pool: [AskPrompt]
        if let plant = scopedPlant {
            pool = AskPrompts.suggestions(for: plant, tasks: store.tasks, observations: store.observations)
        } else {
            pool = AskPrompts.groveSuggestions(
                plants: store.plants,
                tasks: store.tasks,
                observations: store.observations,
                profile: store.profile
            )
        }
        return AskPrompts.curated(pool)
    }

    /// The one question the dark card leads with.
    ///
    /// For the whole grove it is the daily pick, which is stable across the
    /// day and always points at the plant that most needs a person. Scoped to
    /// a plant, it is that plant's most pressing grounded question.
    private var todaysPrompt: AskPrompt? {
        if scopedPlant != nil { return suggestionPool.first }
        return AskPrompts.daily(
            plants: store.plants,
            tasks: store.tasks,
            observations: store.observations,
            profile: store.profile
        )
    }

    /// The deck the hero swipes through: the lead question, then the next
    /// few things worth asking about the same plant, so every page is about
    /// the photo and facts above it.
    private func deck(leadingWith lead: AskPrompt) -> [AskPrompt] {
        let source: [AskPrompt]
        if scopedPlant == nil, let leadPlant = lead.plantID.flatMap(plant(withID:)) {
            source = AskPrompts.curated(
                AskPrompts.suggestions(for: leadPlant, tasks: store.tasks, observations: store.observations)
            )
        } else {
            source = suggestionPool
        }
        let rest = source.filter { $0.id != lead.id && $0.plantID == lead.plantID }
        return [lead] + rest.prefix(AskTodayCard.deckLimit - 1)
    }

    private func plant(withID id: UUID) -> Plant? {
        store.plants.first { $0.id == id }
    }

    private var freeAsksLeft: Int {
        ask.remainingFreeAsks(hasPremium: false)
    }

    private var isDraftEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Plant scope belongs to the carousel, so it remains available while a
    /// question is being written and appears as soon as there is one plant to
    /// choose from.
    private var showsQuickScopeRail: Bool {
        !store.plants.isEmpty
    }

    /// The current plant stays visible even when it would otherwise fall past
    /// the shelf's cap. The remaining slots favour plants the user has recently
    /// asked about, then fall back to the stable order of My Grove.
    private var quickScopePlants: [Plant] {
        let priorityIDs = [scopedPlantID].compactMap { $0 }
            + ask.recentThreads.compactMap(\.plantID)
            + store.plants.map(\.id)
        var seen = Set<UUID>()
        return priorityIDs
            .filter { seen.insert($0).inserted }
            .compactMap { id in store.plants.first { $0.id == id } }
            .prefix(Self.quickScopeLimit)
            .map { $0 }
    }

    private var quickScopeRail: some View {
        AskQuickScopeRail(
            plants: quickScopePlants,
            hiddenPlantCount: max(0, store.plants.count - quickScopePlants.count),
            selection: scopedPlantID,
            onSelect: chooseScope,
            onMore: openScopePicker
        )
    }

    private static let quickScopeLimit = 3
    private static let composerScrollID = "askComposer"

    var body: some View {
        ScrollViewReader { scrollProxy in
            GroveBoardPage(insetsContent: false) {
                askHero
            } sheet: {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, GroveTheme.pagePadding)
                        .groveReveal(0)

                    // The field lives in the sheet, under the title, rather than
                    // docked over the tab bar: the bottom edge belongs to the bar
                    // and the scan disc, and a third floating layer there read as
                    // clutter.
                    composerDock
                        .padding(.horizontal, GroveTheme.pagePadding)
                        .padding(.top, 18)
                        .id(Self.composerScrollID)

                    if showsQuickScopeRail {
                        quickScopeRail
                            .padding(.horizontal, GroveTheme.pagePadding)
                            .padding(.top, GroveTheme.sectionSpacing)
                            .groveReveal(1)
                    }

                    if isDraftEmpty {
                        guidesSection
                            .padding(.top, GroveTheme.sectionSpacing)
                            .groveReveal(3)

                        if !recentThreads.isEmpty {
                            recentSection
                                .padding(.horizontal, GroveTheme.pagePadding)
                                .padding(.top, GroveTheme.sectionSpacing)
                                .groveReveal(4)
                        }
                    }
                }
                .padding(.bottom, 18)
                .animation(GroveMotion.snap, value: isDraftEmpty)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: isComposerFocused) { _, focused in
                guard focused else { return }
                // Let the keyboard finish rising before measuring where the field sits.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(GroveMotion.snap) {
                        scrollProxy.scrollTo(Self.composerScrollID, anchor: .center)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            if store.displayStreak > 0 {
                ToolbarItem(placement: .topBarLeading) {
                    GroveHeaderStreak().groveHeaderChip()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isComposerFocused = false
                    isShowingHistory = true
                } label: {
                    GroveHeaderIcon(symbol: "clock.arrow.circlepath")
                }
                .groveHeaderChip()
                .accessibilityLabel("Conversation history")
                .accessibilityIdentifier("askHistory")
            }
        }
        .groveRootHeaderBar(title: "Ask")
        .task { await premium.load() }
        .sheet(item: $paywallReason) { reason in
            AskPaywallSheet(reason: reason)
        }
        .sheet(isPresented: $isShowingScopePicker) {
            NavigationStack {
                AskScopeSheet(selection: $scopedPlantID)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isShowingHistory, onDismiss: {
            if let threadID = historyThreadToOpen {
                historyThreadToOpen = nil
                open(threadID)
            }
        }) {
            AskHistorySheet { threadID in
                historyThreadToOpen = threadID
                isShowingHistory = false
            }
        }
        .sheet(isPresented: $showsAIConsent, onDismiss: finishAIConsent) {
            AIProcessingConsentView(
                onAgree: {
                    didAgreeToAIConsent = true
                    showsAIConsent = false
                },
                onDecline: {
                    didAgreeToAIConsent = false
                    showsAIConsent = false
                }
            )
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            GroveCameraView(stage: .leaf) { image in
                attachPhoto(image)
            }
        }
        .task(id: selectedPhoto) {
            guard let selectedPhoto else { return }
            await loadPhoto(from: selectedPhoto)
        }
    }

    /// Ari's face beside the tab's name, then the one fact that changes what
    /// the user can do today: how many free questions are left. Premium has no
    /// count to report, so the line becomes Ari's invitation instead.
    /// Ask's hero: Ari's question about a real plant, over that plant's own
    /// photo, edge to edge. With no question to ask, Ari introduces itself.
    @ViewBuilder
    private var askHero: some View {
        if isDraftEmpty, let todaysPrompt {
            todayCard(todaysPrompt)
        } else {
            GroveNightHero {
                AriAvatar(size: 56)
                Text(store.plants.isEmpty ? "Ask Ari about plant care." : "Ask Ari about any of your plants.")
                    .font(GroveTheme.display(GroveDisplayStyle.heading.points))
                    .foregroundStyle(GroveTheme.ink)
            }
        }
    }

    private var header: some View {
        GroveTabHeader(title: "Ask") {
            if premium.showsMeter {
                Button(action: openAllowance) {
                    Text(AskAllowance.line(remaining: freeAsksLeft))
                        .foregroundStyle(freeAsksLeft > 0 ? GroveTheme.mutedInk : GroveTheme.warning)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows Grove Premium")
                .accessibilityIdentifier("askHeaderQuota")
            } else {
                Text("Ari answers from your plants’ own check-ins")
            }
        }
    }

    /// Today's question about a real plant, as Ari's read of it. Swiping
    /// turns to the plant's other questions; the pill sends whichever is
    /// showing, and holding it puts that one in the field for the detail only
    /// the user has.
    private func todayCard(_ prompt: AskPrompt) -> some View {
        AskTodayCard(
            prompts: deck(leadingWith: prompt),
            entry: prompt.plantID.flatMap(plant(withID:)).map {
                TodayBoardEntry(plant: $0, nextTask: store.nextPendingTask(for: $0.id), tasks: store.tasks, siblings: store.plants)
            },
            isDisabled: ask.isAnswering || isLoadingPhoto,
            onAsk: send,
            onEdit: prefill
        )
    }

    /// The first guide the user hasn't read yet. Nil once every one is read,
    /// and the section falls back to a plain shelf.
    private var nextGuide: LearnTopic? {
        LearnLibrary.topics.first { !store.isLessonLearned($0.id) }
    }

    /// Where the user is in the guides, so the subtitle states a fact
    /// rather than a tagline once they've started.
    private var guidesSubtitle: String {
        let total = LearnLibrary.topics.count
        let read = store.learnedLessonCount(in: LearnLibrary.topics)
        switch read {
        case 0: return "Short reads on the basics"
        case total: return "All \(total) read"
        default: return "\(read) of \(total) read"
        }
    }

    /// The Academy lessons, offered where questions start, as a path rather
    /// than a shelf: the next unread guide gets the hero and one action, the
    /// rest wait as small tiles. Each opens the lesson itself, the same screen
    /// the Journey map routes to.
    private var guidesSection: some View {
        let next = nextGuide
        let shelf = LearnLibrary.topics.filter { $0.id != next?.id }

        return VStack(alignment: .leading, spacing: 14) {
            AskSectionTitle(title: "Guides", subtitle: guidesSubtitle)
                .padding(.horizontal, GroveTheme.pagePadding)

            if let next {
                Button {
                    openGuide(next)
                } label: {
                    AskNextGuideCard(
                        topic: next,
                        isFirst: store.learnedLessonCount(in: LearnLibrary.topics) == 0
                    )
                }
                .buttonStyle(GroveCardPressStyle(scale: 0.98))
                .padding(.horizontal, GroveTheme.pagePadding)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(shelf) { topic in
                        Button {
                            openGuide(topic)
                        } label: {
                            AskGuideTile(topic: topic, isLearned: store.isLessonLearned(topic.id))
                        }
                        .buttonStyle(GroveCardPressStyle(scale: 0.97))
                    }
                }
                .padding(.horizontal, GroveTheme.pagePadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("askGuides")
    }

    /// The latest conversations, in the user's own words, so going back to
    /// yesterday's question never needs the clock icon.
    private var recentThreads: [BotanistThread] {
        Array(ask.recentThreads.prefix(3))
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AskSectionTitle(title: "Recent")
                Spacer(minLength: 8)
                Button {
                    isComposerFocused = false
                    isShowingHistory = true
                } label: {
                    Text("See all")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GroveTheme.accentStrong)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See all questions")
            }

            ForEach(Array(recentThreads.enumerated()), id: \.element.id) { index, thread in
                Button {
                    isComposerFocused = false
                    open(thread.id)
                } label: {
                    AskRecentQuestionRow(
                        thread: thread,
                        plant: thread.plantID.flatMap(plant(withID:)),
                        isLast: index == recentThreads.count - 1
                    )
                }
                .buttonStyle(GroveCardPressStyle(scale: 0.99))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("askRecentRail")
    }

    /// Where the question is pointed, said once.
    ///
    /// The dock used to carry a "Whole grove ⌄" capsule directly above the
    /// field while the photo rail at the top of the page carried the same
    /// choice, so one state had two controls forty points apart and neither was
    /// obviously the master. The rail wins: it shows the plants' own faces,
    /// which is the thing being chosen. The field then says out loud what the
    /// rail selected, which is what the capsule was really for.
    private var composerPrompt: String {
        if let scopedPlant { return "Ask Ari about \(scopedPlant.nickname)" }
        switch store.plants.count {
        case 0: return "Ask Ari about plant care"
        case 1: return store.plants.first.map { "Ask Ari about \($0.nickname)" } ?? "Ask Ari about your plant"
        default: return "Ask Ari about your plants"
        }
    }

    /// The tab's centre of gravity. Once there is a draft the suggestion list
    /// steps aside, because a wall of other questions is not what someone
    /// mid-sentence needs.
    private var composerDock: some View {
        VStack(spacing: 10) {
            if let photoDraft {
                BotanistAttachmentPreview(photo: photoDraft) {
                    self.photoDraft = nil
                }
            }
            // The header already says the count. Beside the field it only
            // returns when it is a decision: none left, with the way through.
            if premium.showsMeter, freeAsksLeft == 0 {
                AskQuotaLine(remaining: freeAsksLeft, onUpgrade: openAllowance)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            AskLauncherComposer(
                prompt: composerPrompt,
                draft: $draft,
                isFocused: $isComposerFocused,
                selectedPhoto: $selectedPhoto,
                isLoadingPhoto: isLoadingPhoto,
                hasPhoto: photoDraft != nil,
                onCamera: {
                    isComposerFocused = false
                    isShowingCamera = true
                },
                onSend: sendDraft
            )
            if let photoError {
                Text(photoError)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(AskAllowance.aiDisclosure)
                .font(.caption2)
                .foregroundStyle(GroveTheme.subtleInk)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("askAIDisclosure")
        }
        .animation(GroveMotion.snap, value: photoDraft != nil)
    }

    /// How far the Scan button's disc rises above the tab bar's top edge.
    private static let scanDiscClearance: CGFloat = 26

    // MARK: Actions

    private func openAllowance() {
        Haptics.tap()
        isComposerFocused = false
        paywallReason = freeAsksLeft == 0 ? .limitReached : .browsing
    }

    private func openGuide(_ topic: LearnTopic) {
        isComposerFocused = false
        intentRouter.pushedRoute = AppRoute.learnTopic(topic.id)
    }

    /// A quick reply on the card: the question goes straight into a new
    /// conversation, scoped to the plant it names.
    private func send(_ prompt: AskPrompt) {
        guard !ask.isAnswering, !isLoadingPhoto else { return }
        guard AIProcessingConsent.isGranted() else {
            isComposerFocused = false
            pendingAIConsent = .prompt(prompt)
            didAgreeToAIConsent = false
            showsAIConsent = true
            return
        }
        commit(prompt)
    }

    private func commit(_ prompt: AskPrompt) {
        Haptics.commit()
        isComposerFocused = false
        open(ask.queue(prompt.text, plantID: prompt.plantID ?? scopedPlantID))
    }

    private func chooseScope(_ id: UUID?) {
        guard scopedPlantID != id else { return }
        Haptics.selection()
        withAnimation(GroveMotion.snap) { scopedPlantID = id }
    }

    private func openScopePicker() {
        Haptics.tap()
        isComposerFocused = false
        isShowingScopePicker = true
    }

    /// Loads a starter into the field rather than sending it. The extra beat is
    /// the point: it puts the question in front of the user in their own field,
    /// where they can add the detail only they have before it goes.
    private func prefill(_ prompt: AskPrompt) {
        Haptics.selection()
        // A prompt that names a plant carries its own scope, so the carousel
        // agrees with the question it loaded into the field.
        if let plantID = prompt.plantID { scopedPlantID = plantID }
        withAnimation(GroveMotion.snap) { draft = prompt.text }
        isComposerFocused = true
    }

    private func sendDraft() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isLoadingPhoto,
              question.utf16.count <= AskSession.maxQuestionCharacters else { return }
        guard AIProcessingConsent.isGranted() else {
            isComposerFocused = false
            pendingAIConsent = .draft
            didAgreeToAIConsent = false
            showsAIConsent = true
            return
        }
        commitDraft()
    }

    private func commitDraft() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isLoadingPhoto,
              question.utf16.count <= AskSession.maxQuestionCharacters else { return }
        // A question leaving the field is a commit, not a tap. The heavier
        // knock is the only confirmation the user gets before the conversation
        // screen takes over.
        Haptics.commit()
        withAnimation(GroveMotion.snap) { draft = "" }
        isComposerFocused = false
        let photoData = photoDraft?.data
        photoDraft = nil
        photoError = nil
        open(ask.queue(question, plantID: scopedPlantID, photoData: photoData))
    }

    /// Agreeing sends the draft or quick reply the person already chose.
    /// Declining leaves the draft in the composer and sends nothing.
    private func finishAIConsent() {
        guard didAgreeToAIConsent else {
            pendingAIConsent = nil
            return
        }
        didAgreeToAIConsent = false
        let pending = pendingAIConsent
        pendingAIConsent = nil
        switch pending {
        case .draft:
            commitDraft()
        case .prompt(let prompt):
            commit(prompt)
        case nil:
            break
        }
    }

    private func loadPhoto(from item: PhotosPickerItem) async {
        isLoadingPhoto = true
        photoError = nil
        defer {
            isLoadingPhoto = false
            selectedPhoto = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { throw ScanMediaError.invalidImage }
            try Task.checkCancellation()
            attachPhoto(image)
        } catch is CancellationError {
            return
        } catch {
            photoError = "That photo couldn't be opened. Try another photo."
        }
    }

    private func attachPhoto(_ image: UIImage) {
        do {
            let prepared = try BotanistPhotoDraft(image: image)
            photoError = nil
            withAnimation(GroveMotion.snap) {
                photoDraft = prepared
                if isDraftEmpty { draft = "What can you tell me about this plant?" }
            }
            Haptics.complete()
        } catch {
            photoError = "That photo couldn't be prepared. Try another photo."
        }
    }

    /// Hands the question to the conversation screen and opens it. The sending
    /// itself belongs to that screen so an answer, a failure and a retry all
    /// happen where the user is watching.
    /// Pushed through the router rather than a local `navigationDestination`, so
    /// the tab's own path binding records the push. Without that, `RootView`
    /// still believes it is at the tab root and leaves the tab bar sitting on top
    /// of the conversation's composer.
    private func open(_ threadID: UUID) {
        intentRouter.pushedRoute = AppRoute.askThread(threadID)
    }
}

/// Shared by the tab root and the conversation screen so a follow-up question is
/// grounded exactly like the first one.
@MainActor
func askContext(store: GroveStore, plantID: UUID?, weather: WeatherService? = nil) -> String {
    // Absent until the forecast lands, and absent for good if the grove has no
    // pinned location. Both are ordinary: the context block simply says nothing
    // about the sky rather than guessing at it.
    var sky: GroveForecast?
    if case .loaded(let forecast) = weather?.phase { sky = forecast }

    if let plantID, let plant = store.plants.first(where: { $0.id == plantID }) {
        return BotanistContext.text(
            plant: plant,
            observations: store.observations,
            tasks: store.tasks,
            profile: store.profile,
            diagnoses: store.diagnoses,
            activity: store.activity,
            sky: sky
        )
    }
    return BotanistContext.text(
        plants: store.plants,
        profile: store.profile,
        observations: store.observations,
        tasks: store.tasks,
        sky: sky
    )
}

// MARK: - Scope

/// A small, photo-first shortcut into the Ask scope.
///
/// This is deliberately a shelf rather than the picker itself: it keeps the
/// current plant and a few likely choices one tap away, while the counted final
/// tile hands larger groves to the full named, searchable list below.
private struct AskQuickScopeRail: View {
    let plants: [Plant]
    let hiddenPlantCount: Int
    let selection: UUID?
    let onSelect: (UUID?) -> Void
    let onMore: () -> Void

    var body: some View {
        // No heading. A row of the user's own plants with one of them ticked is
        // already unambiguous, and a 24pt serif "Ask about" over a control was
        // the page's largest type spent on its smallest idea.
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    AskQuickScopeTile(
                        plant: nil,
                        isSelected: selection == nil
                    ) {
                        onSelect(nil)
                    }

                    ForEach(plants) { plant in
                        AskQuickScopeTile(
                            plant: plant,
                            isSelected: selection == plant.id
                        ) {
                            onSelect(plant.id)
                        }
                    }

                    if hiddenPlantCount > 0 {
                        AskQuickScopeMoreTile(count: hiddenPlantCount, action: onMore)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 3)
            }
            .scrollClipDisabled()
        }
        .accessibilityIdentifier("askQuickScopeRail")
    }
}

private struct AskQuickScopeTile: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let plant: Plant?
    let isSelected: Bool
    let action: () -> Void

    private var thumbnailSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 64 : 52
    }

    /// The shelf's rhythm is held by the thumbnails, which never change size.
    /// The caption under them gets enough room to wrap once instead of being
    /// clamped to a single 64pt column: at that width every name longer than
    /// "Pothos" was ellipsized, and "Wild Ora…" is not a plant, it is a bug
    /// report the user reads on the one control that names what they are
    /// asking about.
    private var tileWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 96 : 72
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                thumbnail
                    .frame(width: thumbnailSize, height: thumbnailSize)
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(
                            isSelected ? GroveTheme.accentStrong : GroveTheme.separator,
                            lineWidth: isSelected ? 2.5 : 1
                        )
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(GroveTheme.accentStrong, in: Circle())
                                .overlay { Circle().strokeBorder(GroveTheme.background, lineWidth: 2) }
                                .offset(x: 3, y: 3)
                        }
                    }

                Text(plant?.nickname ?? "Whole grove")
                    .font(.caption.weight(isSelected ? .bold : .semibold))
                    .foregroundStyle(isSelected ? GroveTheme.accentStrong : GroveTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: tileWidth)
            }
            .frame(width: tileWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.96, haptics: false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityHint("Uses this scope for Ari's answer")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("askQuickScope.\(plant?.id.uuidString ?? "grove")")
    }

    private var accessibilityName: String {
        guard let plant else { return "Whole grove" }
        return "\(plant.nickname), \(plant.species)"
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let plant {
            PlantThumbnail(plant: plant, height: thumbnailSize, maxDimension: 180)
        } else {
            AskWholeGroveMark(size: thumbnailSize)
        }
    }

    /// The app's thumbnail radius, not a ratio of the tile.
    ///
    /// A computed `size * 0.32` produced 16.6pt here and 20.5pt on the "more"
    /// tile beside it — two radii nobody chose, neither of them on Grove's
    /// four-step scale, sitting next to each other in one rail.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
    }
}

private struct AskQuickScopeMoreTile: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let count: Int
    let action: () -> Void

    private var thumbnailSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 64 : 52
    }

    private var tileWidth: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 96 : 72
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text("+\(count)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.accentStrong)
                    .frame(width: thumbnailSize, height: thumbnailSize)
                    .background(GroveTheme.softAccent, in: shape)
                    .overlay { shape.strokeBorder(GroveTheme.separator, lineWidth: 1) }

                Text("More")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .frame(width: tileWidth)
            }
            .frame(width: tileWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.96, haptics: false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Choose from \(count) more \(count == 1 ? "plant" : "plants")")
        .accessibilityHint("Opens all plants")
        .accessibilityIdentifier("askQuickScopeMore")
    }

    /// The app's thumbnail radius, not a ratio of the tile.
    ///
    /// A computed `size * 0.32` produced 16.6pt here and 20.5pt on the "more"
    /// tile beside it — two radii nobody chose, neither of them on Grove's
    /// four-step scale, sitting next to each other in one rail.
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
    }
}

/// The picker. The whole grove sits above the plants rather than first among
/// them, because it is a different kind of thing: every other row narrows the
/// answer to one record, and that row is the absence of narrowing.
private struct AskScopeSheet: View {
    @Environment(GroveStore.self) private var store
    @Environment(IntentRouter.self) private var intentRouter
    @Environment(\.dismiss) private var dismiss

    @Binding var selection: UUID?

    @State private var query = ""

    /// Search earns its place only once scrolling has stopped being enough.
    private var showsSearch: Bool { store.plants.count > 10 }

    private var matches: [Plant] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.plants }
        return store.plants.filter {
            $0.nickname.localizedCaseInsensitiveContains(trimmed)
                || $0.species.localizedCaseInsensitiveContains(trimmed)
                || $0.location.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                card { AskScopeRow(plant: nil, isSelected: selection == nil) { choose(nil) } }

                if store.plants.isEmpty {
                    GroveEmptyState(
                        scene: .firstPlant,
                        title: "No plants yet",
                        message: "Ari works best with a plant record. Add one to ask using its photos, check-ins and care history.",
                        artSize: 88
                    ) {
                        Button { addPlant() } label: {
                            GroveScanCTALabel(title: "Add a plant")
                        }
                        .buttonStyle(GroveScanCTAStyle())
                        .accessibilityLabel("Add a plant")
                    }
                    .groveCard(padding: 16)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Your plants")
                        if matches.isEmpty {
                            Text("No plant here matches “\(query)”.")
                                .font(.subheadline)
                                .foregroundStyle(GroveTheme.mutedInk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .groveCard(padding: 16)
                        } else {
                            card {
                                ForEach(Array(matches.enumerated()), id: \.element.id) { index, plant in
                                    AskScopeRow(plant: plant, isSelected: selection == plant.id) {
                                        choose(plant.id)
                                    }
                                    if index < matches.count - 1 {
                                        SuggestionSeparator()
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding)
            .padding(.bottom, GroveTheme.pageBottomPadding)
        }
        .groveBackground()
        .groveEditorialPage("Ask Ari about")
        .searchableIf(showsSearch, text: $query, prompt: GroveSearchField.prompt)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: { GroveHeaderIcon(symbol: "xmark") }
                    .accessibilityLabel("Close")
            }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .groveCard(padding: 0)
            .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
    }

    private func choose(_ id: UUID?) {
        Haptics.selection()
        selection = id
        dismiss()
    }

    /// Dismiss first so the camera cover is presented by the app shell rather
    /// than competing with this sheet's dismissal animation.
    private func addPlant() {
        dismiss()
        Task { @MainActor in
            await Task.yield()
            intentRouter.startScan(.add)
        }
    }
}

/// Scope rows share a flat card, so their pressed state tints in place instead
/// of scaling one row away from its neighbours.
private struct SuggestionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? GroveTheme.softAccent : Color.clear)
            .animation(GroveMotion.snap, value: configuration.isPressed)
    }
}

private struct AskScopeRow: View {
    let plant: Plant?
    let isSelected: Bool
    let action: () -> Void

    private static let thumbnailSize: CGFloat = 40

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(plant?.nickname ?? "Whole grove")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                // The same dot the grid uses, for the same reason: the plant you
                // most likely came here to ask about is the one in trouble.
                if let band = plant?.healthBand, band == .urgent || band == .attention {
                    Circle().fill(band.color).frame(width: 7, height: 7)
                }
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.accentStrong)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SuggestionPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(plant.map { "\($0.nickname), \($0.species)" } ?? "Whole grove")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var subtitle: String {
        guard let plant else { return "Any plant question, with your grove in context" }
        // An unplaced plant has no location worth naming, and a bare
        // separator after the species reads as a rendering fault.
        let location = plant.location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty, location != "Unassigned" else { return plant.species }
        return "\(plant.species) · \(location)"
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let plant {
            PlantThumbnail(plant: plant, height: Self.thumbnailSize, maxDimension: 160)
                .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: Self.thumbnailSize * 0.34, style: .continuous))
        } else {
            AskWholeGroveMark(size: Self.thumbnailSize)
        }
    }
}

/// The grove scope is a collection rather than a generic grid. Its bespoke
/// planter stays visually related to plant thumbnails while the soft tile keeps
/// its silhouette calm at both picker and pill sizes.
private struct AskWholeGroveMark: View {
    let size: CGFloat

    var body: some View {
        Image("AskWholeGrove")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .background(
                GroveTheme.softAccent,
                in: RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
            )
    }
}

private extension View {
    /// `searchable` is unconditional by nature; a small grove does not need a
    /// search field taking the top of the sheet.
    @ViewBuilder
    func searchableIf(_ enabled: Bool, text: Binding<String>, prompt: String) -> some View {
        if enabled {
            searchable(text: text, prompt: prompt)
        } else {
            self
        }
    }
}

// MARK: - Launcher

/// Ari's face, used at 56pt beside the tab's title and at 32pt beside every
/// answer, so the expert is visually continuous from the first question on.
private struct AriAvatar: View {
    let size: CGFloat

    var body: some View {
        Image("GroveBotanist")
            .resizable()
            .scaledToFit()
            .padding(size * 0.1)
            .frame(width: size, height: size)
            .background(GroveTheme.softAccent, in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(GroveTheme.edgeLight, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

/// The allowance, said in one sentence wherever it appears.
enum AskAllowance {
    static func line(remaining: Int) -> String {
        switch remaining {
        case ..<1: "You've used today's free questions"
        case 1: "1 free question left today"
        default: "\(remaining) free questions left today"
        }
    }

    /// Said wherever the allowance is spent. The gateway still answers a
    /// recognised emergency (a pet or child eating a plant, sap in the eyes)
    /// for free, and someone in that moment must not read "used up" and give up.
    static let safetyStillAnswered = "Urgent safety questions, like a pet or child eating a plant, are still answered."

    /// The one-line disclosure under Ari's composer.
    static let aiDisclosure = "Ari is an AI (Google Gemini). Check anything important, and in an emergency call a vet or poison line."
}

/// A section's name and, when it helps, the fact that explains it. The same
/// anatomy as Today's board sections.
private struct AskSectionTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Today's question, as Ari's read of one plant.
///
/// Ask's hero is Ari speaking, so it sits on night green. It opens on the same
/// row Today's board draws for the plant (photo, lit dot, three-letter code,
/// status) so the plant reads as the same object on both tabs. Then comes the
/// question at heading size, then the three facts behind it in small caps.
/// Showing why Ari is asking is what earns the tap.
///
/// The question is a deck. Swiping turns to the plant's next question while
/// the photo and facts hold still, so it feels like flicking through what Ari
/// has been wondering about this one plant. The outgoing line fades as the
/// next arrives, the card's height follows the finger from one question's
/// length to the next, and each settle ticks.
/// One white pill sends whichever question is showing; holding it puts that
/// question in the field to edit first.
private struct AskTodayCard: View {
    /// Enough to browse, few enough that every page still feels chosen.
    static let deckLimit = 5

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let prompts: [AskPrompt]
    let entry: TodayBoardEntry?
    let isDisabled: Bool
    let onAsk: (AskPrompt) -> Void
    let onEdit: (AskPrompt) -> Void

    @State private var shownID: String?
    /// Each page's natural height, so the deck can be exactly as tall as the
    /// question under the finger rather than as tall as the longest one.
    @State private var pageHeights: [String: CGFloat] = [:]
    /// Scroll position in pages: 1.5 is halfway from the second to the third.
    @State private var scrollPage: CGFloat = 0

    /// The question on screen. Falls back to the lead whenever the deck is
    /// rebuilt underneath a page that no longer exists.
    private var prompt: AskPrompt {
        prompts.first { $0.id == shownID } ?? prompts[0]
    }

    private var shownIndex: Int {
        prompts.firstIndex { $0.id == prompt.id } ?? 0
    }

    var body: some View {
        GroveNightHero {
            VStack(alignment: .leading, spacing: 0) {
                if let entry {
                    plantRow(entry)
                        .padding(.bottom, 6)
                } else {
                    groveLine
                }

                questionDeck
                    .padding(.top, 20)

                if prompts.count > 1 {
                    pager
                        .padding(.top, 10)
                }

                if let entry {
                    stats(entry)
                        .padding(.top, 18)
                }

                askButton
                    .padding(.top, entry == nil ? 20 : 4)
            }
        }
        .groveHaptic(shownIndex) { _ in Haptics.selection() }
        .onChange(of: prompts.map(\.id)) { _, ids in
            if let shownID, !ids.contains(shownID) { self.shownID = nil }
        }
    }

    /// Today's board row, lit for night green: the dot rings the photo in the
    /// hero's own colour, and the code sits in the map's code ink.
    private func plantRow(_ entry: TodayBoardEntry) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 8) {
                PlantThumbnail(plant: entry.plant, height: 56, maxDimension: 220)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(entry.mapTint)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(GroveTheme.mapGround, lineWidth: 3))
                            .offset(x: 4, y: 4)
                    }
                Text(entry.code)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(GroveTheme.mapCode)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.plant.nickname)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                GroveStatusLabel(status: entry.status, lineLimit: 1)
            }
            .padding(.top, 6)
            .accessibilityElement(children: .combine)
        }
    }

    /// A question about the whole grove has no plant row, so its reason
    /// stands in as the small-caps line above it.
    private var groveLine: some View {
        Text((prompt.reason ?? "Your grove").uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(GroveTheme.mapCaption)
            .lineLimit(1)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.2), value: prompt.id)
    }

    /// The deck's height mid-swipe: the two questions either side of the
    /// finger, blended by how far it has travelled between them.
    private var deckHeight: CGFloat? {
        guard !prompts.isEmpty else { return nil }
        let clamped = min(max(scrollPage, 0), CGFloat(prompts.count - 1))
        let lower = Int(clamped.rounded(.down))
        let upper = min(lower + 1, prompts.count - 1)
        guard let a = pageHeights[prompts[lower].id],
              let b = pageHeights[prompts[upper].id] else { return nil }
        return a + (b - a) * (clamped - CGFloat(lower))
    }

    /// The questions as pages, clipped to the hero's margins. Only the page
    /// in view is drawn at full strength; its neighbours fade to nothing by
    /// the time they reach the edge, so nothing ghosts in at the side.
    private var questionDeck: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: GroveTheme.pagePadding) {
                ForEach(prompts) { page in
                    Text(page.text)
                        .font(GroveTheme.display(GroveDisplayStyle.heading.points))
                        .tracking(-0.4)
                        .foregroundStyle(Color.white)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .containerRelativeFrame(.horizontal)
                        // Measured after the page takes the container's width,
                        // so a two-line question isn't sized as one line and
                        // spill up over the plant row.
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            pageHeights[page.id] = $0
                        }
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            content
                                .opacity(1 - abs(phase.value))
                                .offset(x: reduceMotion ? 0 : phase.value * -24)
                        }
                        .id(page.id)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollPosition(id: $shownID, anchor: .leading)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            let stride = geometry.containerSize.width + GroveTheme.pagePadding
            return stride > 0 ? geometry.contentOffset.x / stride : 0
        } action: { _, page in
            scrollPage = page
        }
        .frame(height: deckHeight, alignment: .top)
        .scrollDisabled(prompts.count < 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(prompt.text)
        .accessibilityValue(prompts.count > 1 ? "Question \(shownIndex + 1) of \(prompts.count)" : "")
        .accessibilityAddTraits(.isHeader)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: turn(to: shownIndex + 1)
            case .decrement: turn(to: shownIndex - 1)
            @unknown default: break
            }
        }
    }

    /// Where the deck is, as short bars: the current one long and white, the
    /// rest short and dim. A tap on a bar turns straight to that question.
    private var pager: some View {
        HStack(spacing: 6) {
            ForEach(Array(prompts.enumerated()), id: \.element.id) { index, page in
                let isShown = index == shownIndex
                Capsule()
                    .fill(isShown ? Color.white : Color.white.opacity(0.24))
                    .frame(width: isShown ? 22 : 6, height: 6)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .onTapGesture { turn(to: index) }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: shownIndex)
        .accessibilityHidden(true)
    }

    /// The same three cells as the plant's row on Today, under a room hairline.
    private func stats(_ entry: TodayBoardEntry) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 10))
        return layout {
            GroveStatCell(label: entry.nextLabel, value: entry.nextValue, tint: entry.nextTint)
            GroveStatCell(label: "Waters every", value: entry.rhythmValue)
            GroveStatCell(label: "Health", value: "\(entry.plant.healthScore)", trend: entry.plant.trend)
        }
        .padding(.top, 14)
        .padding(.bottom, 18)
        .overlay(alignment: .top) {
            Rectangle().fill(GroveTheme.mapRoom).frame(height: 1)
        }
    }

    private var askButton: some View {
        Button {
            onAsk(prompt)
        } label: {
            Text("Ask Ari")
                .font(.body.weight(.semibold))
                .foregroundStyle(GroveTheme.inkOnLight)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Capsule().fill(Color.white))
                .contentShape(Capsule())
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.97))
        .disabled(isDisabled)
        .contextMenu {
            Button {
                onEdit(prompt)
            } label: {
                Label("Edit before sending", systemImage: "pencil")
            }
        }
        .accessibilityLabel("Ask Ari: \(prompt.text)")
        .accessibilityHint("Sends this question to Ari.")
        .accessibilityAction(named: "Edit before sending") { onEdit(prompt) }
        .accessibilityIdentifier("askStarterRail")
    }

    private func turn(to index: Int) {
        guard prompts.indices.contains(index) else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.86)) {
            shownID = prompts[index].id
        }
    }
}

/// Capsules wrap like chips, and stack one per line at accessibility sizes,
/// where a single capsule can be wider than the screen.
enum AskCapsuleLayout {
    static func make<Content: View>(stacked: Bool, @ViewBuilder content: () -> Content) -> some View {
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(GroveFlowLayout(spacing: 8))
        return layout(content)
    }
}

/// The next unread guide as the section's hero: the lesson's art edge to
/// edge, its title and hook set low on a scrim, and one action. The card
/// grows with Dynamic Type rather than clipping the type into the art.
private struct AskNextGuideCard: View {
    let topic: LearnTopic
    /// Nobody has read a guide yet, so "Up next" would imply a path they
    /// never started.
    let isFirst: Bool

    private static let minHeight: CGFloat = 230
    private static let onPhoto = Color.white

    private var caption: String {
        "\(isFirst ? "Start here" : "Up next") · \(topic.readMinutes) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .monospacedDigit()
                .foregroundStyle(Self.onPhoto.opacity(0.9))
            Text(topic.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(Self.onPhoto)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(topic.subtitle)
                .font(.subheadline)
                .foregroundStyle(Self.onPhoto)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text("Start reading")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroveTheme.inkOnLight)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Self.onPhoto, in: Capsule())
                .padding(.top, 10)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: Self.minHeight, alignment: .bottomLeading)
        .background {
            Image(topic.heroArtworkName)
                .resizable()
                .scaledToFill()
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: GroveTheme.mapGround.opacity(0), location: 0.15),
                            .init(color: GroveTheme.mapGround.opacity(0.9), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .accessibilityHidden(true)
        }
        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(isFirst ? "Start here" : "Up next"): \(topic.title). \(topic.subtitle). \(topic.readMinutes) minute read")
        .accessibilityAddTraits(.isButton)
    }
}

/// One of the other guides, small enough that the hero stays the obvious
/// tap. A read guide says so instead of its length.
private struct AskGuideTile: View {
    let topic: LearnTopic
    let isLearned: Bool

    private static let width: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(topic.heroArtworkName)
                .resizable()
                .scaledToFill()
                .frame(width: Self.width, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(topic.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if isLearned {
                    Label("Read", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(GroveTheme.accentStrong)
                } else {
                    Text("\(topic.readMinutes) min")
                        .font(.footnote)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .monospacedDigit()
                }
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLearned ? "\(topic.title), read" : "\(topic.title), \(topic.readMinutes) minute read")
        .accessibilityAddTraits(.isButton)
    }
}

/// One conversation the user already had: the plant's photo, the question in
/// their own words over two lines, and where and when underneath.
private struct AskRecentQuestionRow: View {
    let thread: BotanistThread
    let plant: Plant?
    var isLast = false

    private static let thumbnailSize: CGFloat = 44

    /// The question without the plant's name welded to the front of it.
    ///
    /// Questions asked from a plant's page are stored with the plant named in
    /// the opening clause, so the row spent its first line repeating the label
    /// printed directly beneath it. Only a leading, comma-terminated mention is
    /// removed, and only when the row is showing the plant anyway.
    private var title: String {
        guard let plant else { return thread.title }
        let prefix = plant.nickname + ","
        guard thread.title.lowercased().hasPrefix(prefix.lowercased()) else { return thread.title }
        let rest = thread.title.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard let first = rest.first else { return thread.title }
        return first.uppercased() + rest.dropFirst()
    }

    private var meta: String {
        "\(plant?.nickname ?? "Your grove") · \(AskDateText.short(thread.updatedAt))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(GroveTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta)
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(GroveTheme.separator).frame(height: 1)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let plant {
            PlantThumbnail(plant: plant, height: Self.thumbnailSize, maxDimension: 160)
                .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
        } else {
            AskWholeGroveMark(size: Self.thumbnailSize)
        }
    }
}

/// Dates on the Ask screens: a weekday inside the last week, a day and month
/// after that.
enum AskDateText {
    static func short(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        if days == 1 { return "Yesterday" }
        if days > 1, days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// The launcher's composer: one white capsule with the photo button, the
/// field and the ink send button. Plant scope is chosen in the rail above.
private struct AskLauncherComposer: View {
    let prompt: String
    @Binding var draft: String
    @FocusState.Binding var isFocused: Bool
    @Binding var selectedPhoto: PhotosPickerItem?
    let isLoadingPhoto: Bool
    let hasPhoto: Bool
    let onCamera: () -> Void
    let onSend: () -> Void

    private var trimmed: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isOverLimit: Bool {
        trimmed.utf16.count > AskSession.maxQuestionCharacters
    }

    private var canSend: Bool { !trimmed.isEmpty && !isOverLimit && !isLoadingPhoto }

    /// Silent until the limit is close enough to matter.
    private var remaining: Int {
        AskSession.maxQuestionCharacters - trimmed.utf16.count
    }

    private var showsRemaining: Bool { remaining <= 80 }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .bottom, spacing: 8) {
                photoMenu

                TextField(
                    "",
                    text: $draft,
                    prompt: Text(prompt)
                        .foregroundStyle(GroveTheme.subtleInk),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(GroveTheme.ink)
                .lineLimit(1...6)
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit(onSend)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: Self.controlSize, alignment: .leading)
                .accessibilityLabel("Your question")
                .accessibilityIdentifier("askLauncherComposer")

                AskSendButton(isReady: canSend, action: onSend)
            }
            .padding(Self.inset)
            .background(GroveTheme.surface, in: shape)
            .overlay {
                shape.strokeBorder(
                    isFocused ? GroveTheme.accent.opacity(0.5) : GroveTheme.separator,
                    lineWidth: 1
                )
            }
            .shadow(color: GroveTheme.contactShadow, radius: 1, y: 1)
            .shadow(
                color: GroveTheme.shadow,
                radius: isFocused ? GroveElevation.floating.radius : GroveElevation.resting.radius,
                y: isFocused ? GroveElevation.floating.y : GroveElevation.resting.y
            )
            .contentShape(shape)
            .onTapGesture { isFocused = true }
            .animation(GroveMotion.snap, value: isFocused)
            .animation(GroveMotion.snap, value: draft)

            if isOverLimit {
                counter("\(AskSession.maxQuestionCharacters.formatted()) characters maximum", tint: GroveTheme.warning)
                    .accessibilityIdentifier("askLauncherQuestionLimit")
            } else if showsRemaining {
                counter("\(remaining) characters left", tint: GroveTheme.subtleInk)
            }
        }
        .animation(GroveMotion.snap, value: isOverLimit)
        .animation(GroveMotion.snap, value: showsRemaining)
    }

    /// One button for both photo sources, so the bar holds three things.
    private var photoMenu: some View {
        Menu {
            Button(action: onCamera) {
                Label("Take a photo", systemImage: "camera")
            }
            .accessibilityIdentifier("askLauncherCamera")
            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label(hasPhoto ? "Replace the photo" : "Choose a photo", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("askLauncherPhotoPicker")
        } label: {
            Group {
                if isLoadingPhoto {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: hasPhoto ? "camera.fill" : "camera")
                        .font(.system(size: 17, weight: .medium))
                }
            }
            .foregroundStyle(GroveTheme.ink)
            .frame(width: Self.controlSize, height: Self.controlSize)
            .background(GroveTheme.secondarySurface, in: Circle())
        }
        .disabled(isLoadingPhoto)
        .accessibilityLabel(hasPhoto ? "Replace the photo" : "Add a photo")
    }

    private func counter(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .transition(.opacity.combined(with: .offset(y: -6)))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
    }

    /// The bar's discs.
    static let controlSize: CGFloat = 42
    private static let inset: CGFloat = 7
    /// Concentric with the discs inside it, so a one-line bar is a capsule.
    private static let radius: CGFloat = inset + controlSize / 2
}

/// The ink send disc. Dimmed until there is something to send, then full ink
/// with a small spring.
private struct AskSendButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isReady: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(GroveTheme.background)
                .frame(width: AskLauncherComposer.controlSize, height: AskLauncherComposer.controlSize)
                .background(GroveTheme.ink.opacity(isReady ? 1 : 0.28), in: Circle())
                .scaleEffect(reduceMotion || isReady ? 1 : 0.92)
        }
        .buttonStyle(GrovePressStyle())
        .disabled(!isReady)
        .animation(reduceMotion ? .easeOut(duration: 0.16) : GroveMotion.pop, value: isReady)
        .accessibilityLabel("Send question")
        .accessibilityIdentifier("askLauncherSend")
    }
}

// MARK: - Rows

/// Inset to the words, the way a grouped list separates its rows — a full-bleed
/// rule would cut the glyph column in half.
private struct SuggestionSeparator: View {
    var body: some View {
        Rectangle()
            .fill(GroveTheme.separator)
            .frame(height: 1)
            .padding(.leading, 54)
    }
}

private struct RecentThreadRow: View {
    let thread: BotanistThread
    let plant: Plant?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(thread.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(GroveTheme.subtleInk.opacity(0.65))
                    .accessibilityHidden(true)
            }

            HStack(spacing: 7) {
                if let plant {
                    Image(systemName: "leaf.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(GroveTheme.accent)
                    Text(plant.nickname)
                        .lineLimit(1)
                    Text("·")
                }
                Text(thread.updatedAt, format: .dateTime.month(.abbreviated).day())
            }
            .font(.subheadline)
            .foregroundStyle(GroveTheme.subtleInk)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GroveTheme.surface,
            in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
        )
        .groveEdgeLight(radius: GroveTheme.cardRadius)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A custom-layout counterpart to `List.swipeActions`. The Ask tab keeps its
/// editorial card layout inside a `ScrollView`, where the system modifier does
/// not reveal actions, so this supplies the familiar trailing Delete affordance
/// without replacing the whole page with a `List`.
private struct SwipeToDeleteQuestion<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onDelete: () -> Void
    let content: Content

    @State private var horizontalOffset: CGFloat = 0
    @State private var isRevealed = false

    private let actionWidth: CGFloat = 84

    init(
        onDelete: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.onDelete = onDelete
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive, action: requestDelete) {
                VStack(spacing: 5) {
                    Image(systemName: "trash.fill")
                        .font(.headline)
                    Text("Delete")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .frame(width: actionWidth)
                .frame(maxHeight: .infinity)
                .background(
                    GroveTheme.danger,
                    in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .opacity(actionReveal)
            .allowsHitTesting(isRevealed)
            .accessibilityHidden(!isRevealed)

            content
                .offset(x: horizontalOffset)
                .contentShape(Rectangle())
                // When the action is open, a tap closes it instead of following
                // the NavigationLink hidden inside `content`.
                .disabled(isRevealed)
                .onTapGesture {
                    guard isRevealed else { return }
                    settle(revealed: false)
                }
                .simultaneousGesture(swipeGesture)
                .accessibilityHint("Swipe left to reveal the Delete action")
                .accessibilityAction(named: "Delete question", requestDelete)
        }
    }

    private var actionReveal: Double {
        min(1, max(0, Double(-horizontalOffset / actionWidth)))
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let origin = isRevealed ? -actionWidth : 0
                horizontalOffset = max(
                    -actionWidth * 1.35,
                    min(0, origin + value.translation.width)
                )
            }
            .onEnded { value in
                guard abs(value.predictedEndTranslation.width) > abs(value.predictedEndTranslation.height) else {
                    settle(revealed: isRevealed)
                    return
                }

                let origin = isRevealed ? -actionWidth : 0
                let projected = origin + value.predictedEndTranslation.width
                if projected < -actionWidth * 1.4 {
                    requestDelete()
                } else {
                    settle(revealed: projected < -actionWidth * 0.55)
                }
            }
    }

    private func requestDelete() {
        settle(revealed: false)
        onDelete()
    }

    private func settle(revealed: Bool) {
        isRevealed = revealed
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : GroveMotion.snap) {
            horizontalOffset = revealed ? -actionWidth : 0
        }
    }
}

// MARK: - Quota

/// The day's allowance, spoken once, in the field's own footnote voice.
///
/// It used to run as a second toolbar — a bubble glyph, a muted count, a bold
/// green link — three objects competing with the composer they described. One
/// sentence and one weight, with the link only a step louder than the words
/// around it, keeps the line useful without letting it lead the dock.
private struct AskQuotaLine: View {
    let remaining: Int
    let onUpgrade: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                Text(AskAllowance.line(remaining: remaining))
                    .foregroundStyle(remaining > 0 ? GroveTheme.mutedInk : GroveTheme.warning)
                Text("·")
                    .foregroundStyle(GroveTheme.subtleInk.opacity(0.6))
                    .accessibilityHidden(true)
                Button(action: onUpgrade) {
                    Text("Ask without limits")
                        .fontWeight(.semibold)
                }
                .foregroundStyle(GroveTheme.accentStrong)
            }
            .font(.caption)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("botanistQuota")

            if remaining == 0 {
                Text(AskAllowance.safetyStillAnswered)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("botanistSafetyStillAnswered")
            }
        }
    }
}

// The streak pill that stood here now lives with the rest of the streak, in
// StreakDetailSheet.swift, mounted by `groveRootHeaderBar` on all four tabs.

// MARK: - Reward toast

private struct AskRewardToast: View {
    let reward: GroveStore.LearnReward
    let streak: Int

    var body: some View {
        HStack(spacing: 12) {
            SproutMascot(expression: .happy, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Asked and answered")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)
                HStack(spacing: 10) {
                    GroveStatLabel(text: "+\(reward.xp) XP", symbol: "bolt.fill", tint: GroveTheme.accentStrong)
                    if streak > 0 {
                        GroveStatLabel(text: "\(streak)-day streak", symbol: "flame.fill", tint: GroveTheme.streak)
                    }
                }
                .font(.caption.weight(.bold))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                .stroke(GroveTheme.accent.opacity(0.4), lineWidth: 1)
        }
        .groveShadow(.floating)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Question answered. \(reward.xp) XP.\(streak > 0 ? " \(streak) day streak." : "")")
    }
}

// MARK: - Conversation

private struct BotanistPhotoDraft {
    let data: Data
    let preview: UIImage

    init(data: Data, preview: UIImage) {
        self.data = data
        self.preview = preview
    }

    @MainActor init(image: UIImage) throws {
        guard let payload = image.preparedForPlantAnalysis().boundedPlantAnalysisJPEG(
            maximumBytes: AskSession.maxPhotoBytes
        ) else { throw ScanMediaError.invalidImage }
        data = payload.data
        preview = payload.image
    }
}

private struct BotanistAttachmentPreview: View {
    let photo: BotanistPhotoDraft
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(uiImage: photo.preview)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
            Text("Photo attached")
                .font(.caption.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(GroveTheme.subtleInk)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove attached photo")
        }
        .padding(8)
        .background(GroveTheme.secondarySurface, in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
    }
}

private struct AskHistorySheet: View {
    @Environment(AskSession.self) private var ask
    @Environment(GroveStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: BotanistThread?
    let onOpen: (UUID) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(ask.recentThreads) { thread in
                    Button { onOpen(thread.id) } label: {
                        RecentThreadRow(
                            thread: thread,
                            plant: thread.plantID.flatMap { id in store.plants.first { $0.id == id } }
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(GroveTheme.background)
                    .swipeActions {
                        Button("Delete", role: .destructive) { pendingDeletion = thread }
                    }
                    .contextMenu {
                        Button("Delete conversation", role: .destructive) { pendingDeletion = thread }
                    }
                }
            }
            .overlay {
                if ask.recentThreads.isEmpty {
                    ContentUnavailableView(
                        "No conversations yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Your conversations with Ari will appear here after your first question.")
                    )
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete this conversation?", isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ), titleVisibility: .visible, presenting: pendingDeletion) { thread in
                Button("Delete", role: .destructive) { ask.delete(threadID: thread.id) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This deletes every question and answer in it from this iPhone. There is no undo.")
            }
        }
    }
}

/// One botanist conversation: the turns so far, a composer for follow-ups, and
/// the single place in the app that actually sends a question.
struct AskThreadView: View {
    let threadID: UUID

    @Environment(GroveStore.self) private var store
    @Environment(AskSession.self) private var ask
    @Environment(GrovePremiumStore.self) private var premium
    @Environment(WeatherService.self) private var weather
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var draft: String
    @State private var reward: GroveStore.LearnReward?
    @State private var paywallReason: AskPaywallSheet.Reason?
    @State private var isConfirmingDeletion = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photoDraft: BotanistPhotoDraft?
    @State private var photoError: String?
    @State private var isLoadingPhoto = false
    @State private var hasSeenAnsweringStart = false

    init(threadID: UUID, initialDraft: String = "") {
        self.threadID = threadID
        _draft = State(initialValue: initialDraft)
    }

    private var thread: BotanistThread? { ask.thread(id: threadID) }

    private var plant: Plant? {
        thread?.plantID.flatMap { id in store.plants.first { $0.id == id } }
    }

    private var canSend: Bool {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !question.isEmpty
            && question.utf16.count <= AskSession.maxQuestionCharacters
            && !isAnswering
            && !isLoadingPhoto
    }

    /// Scoped to this conversation: a question in flight somewhere else must not
    /// freeze this composer or borrow this thread's thinking bubble.
    private var isAnswering: Bool { ask.isAnswering(in: threadID) }

    private var isConversationEmpty: Bool {
        thread?.messages.isEmpty ?? true
    }

    private var starterPrompts: [AskPrompt] {
        guard let plant else { return [] }
        return Array(
            AskPrompts.suggestions(
                for: plant,
                tasks: store.tasks,
                observations: store.observations
            )
            .prefix(3)
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // The header already names the plant and what Ari is
                    // reading. The fuller card is the introduction, so it
                    // stands only until the conversation starts.
                    if isConversationEmpty, !isAnswering {
                        groundingNote
                    }

                    if isConversationEmpty,
                       draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       !isAnswering,
                       !starterPrompts.isEmpty {
                        conversationStarters
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    ForEach(thread?.messages ?? []) { message in
                        MessageBubble(message: message, threadID: threadID)
                            .id(message.id)
                    }

                    if isAnswering {
                        ThinkingBubble(plantName: plant?.nickname)
                            .id(Self.thinkingAnchor)
                    }

                    if let failure = ask.failureMessage(in: threadID), !isAnswering {
                        FailureNotice(message: failure) {
                            retry()
                        }
                    }
                }
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, GroveTheme.pageTopPadding)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: thread?.messages.count ?? 0) { _, _ in
                scrollToEnd(proxy)
            }
            .onChange(of: isAnswering) { wasAnswering, nowAnswering in
                scrollToEnd(proxy)
                if nowAnswering {
                    hasSeenAnsweringStart = true
                } else if wasAnswering, hasSeenAnsweringStart {
                    hasSeenAnsweringStart = false
                    announceAnswerIfNeeded()
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .groveBackground()
        .navigationTitle(plant?.nickname ?? "Ask Ari")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // The same action as the press-and-hold on the tab root, reachable from
        // inside the conversation — reading an answer back is usually where a
        // person decides they are done with it.
        .toolbar {
            ToolbarItem(placement: .principal) {
                AskThreadTitle(plant: plant, subtitle: threadSubtitle)
            }
            if !isConversationEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            isConfirmingDeletion = true
                        } label: {
                            Label("Delete conversation", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Conversation options")
                }
            }
        }
        .confirmationDialog(
            "Delete this conversation?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Haptics.warning()
                // The list this pops back to is closing over the gap behind the
                // dismissal, so the mutation is animated even though this view
                // is on its way out.
                withAnimation(GroveMotion.settle) { ask.delete(threadID: threadID) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every question and answer in it from this iPhone. There is no undo.")
        }
        .task(id: threadID) {
            // A question chosen on the tab root is sent here, once.
            if let queued = ask.takePendingQuestion(for: threadID) {
                await perform(queued.question, photoData: queued.photoData)
            }
        }
        .task(id: selectedPhoto) {
            guard let selectedPhoto else { return }
            await loadPhoto(from: selectedPhoto)
        }
        .onDisappear {
            // Backing out of an untouched composer should not leave an empty
            // conversation in the recents list.
            ask.discardIfEmpty(threadID: threadID)
        }
        .sheet(item: $paywallReason) { reason in
            AskPaywallSheet(reason: reason)
        }
        .overlay(alignment: .top) {
            if let reward {
                AskRewardToast(reward: reward, streak: store.displayStreak)
                    .padding(.horizontal, GroveTheme.pagePadding)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(3.5))
                        withAnimation(GroveMotion.settle) { self.reward = nil }
                    }
            }
        }
    }

    private static let thinkingAnchor = "ask-thinking"

    /// Who is answering and what they are reading, counted from the record.
    private var threadSubtitle: String {
        guard let plant else {
            let count = store.plants.count
            return count == 0 ? "Ari" : "Ari · from \(count) \(count == 1 ? "plant" : "plants")"
        }
        let checkIns = store.observations(for: plant.id).count
        guard checkIns > 0 else { return "Ari · from its plant record" }
        return "Ari · from \(checkIns) check-in\(checkIns == 1 ? "" : "s")"
    }

    /// Says out loud what the botanist was given. The grounding is the product —
    /// leaving it invisible would make a well-informed answer look like a lucky
    /// guess, and would hide from the user what was shared to get it.
    @ViewBuilder
    private var groundingNote: some View {
        if let plant {
            BotanistPlantContextCard(plant: plant)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(GroveTheme.accentStrong)
                Text("Ari is using an overview of your grove.")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GroveTheme.softAccent,
                in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
            )
        }
    }

    private var conversationStarters: some View {
        VStack(alignment: .leading, spacing: 12) {
            AskSectionTitle(
                title: "What are you noticing?",
                subtitle: "Start with a suggested question, or write your own below."
            )

            AskCapsuleLayout.make(stacked: dynamicTypeSize.isAccessibilitySize) {
                ForEach(starterPrompts) { prompt in
                    Button {
                        Task { await perform(prompt.text) }
                    } label: {
                        Text(prompt.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GroveTheme.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .frame(minHeight: 44)
                            .overlay {
                                Capsule().strokeBorder(GroveTheme.separator, lineWidth: 1.5)
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(GroveCardPressStyle(scale: 0.96))
                    .disabled(isAnswering)
                    .accessibilityLabel("Ask: \(prompt.text)")
                }
            }
        }
        .padding(.top, 4)
    }

    private var composer: some View {
        let hasAttachedPhoto = photoDraft != nil
        let isPreparingPhoto = isLoadingPhoto
        let reusedPhotoCount = ask.reusablePhotoCount(in: threadID)
        return VStack(spacing: 8) {
            if premium.showsMeter {
                AskQuotaLine(
                    remaining: ask.remainingFreeAsks(hasPremium: false)
                ) {
                    paywallReason = ask.remainingFreeAsks(hasPremium: false) == 0
                        ? .limitReached
                        : .browsing
                }
            }

            if let photoDraft {
                HStack(spacing: 10) {
                    Image(uiImage: photoDraft.preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Photo attached")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(GroveTheme.ink)
                        Text("Location data removed before it is analysed")
                            .font(.caption2)
                            .foregroundStyle(GroveTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 4)

                    Button {
                        Haptics.tap()
                        withAnimation(GroveMotion.snap) { self.photoDraft = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(GroveTheme.subtleInk)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove attached photo")
                }
                .padding(8)
                .background(
                    GroveTheme.softAccent,
                    in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if reusedPhotoCount > 0 {
                HStack(spacing: 9) {
                    Image(systemName: reusedPhotoCount > 1 ? "photo.stack.fill" : "photo.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(GroveTheme.accentStrong)

                    Text(
                        reusedPhotoCount > 1
                            ? "Using your two most recent photos for comparison"
                            : "Using your earlier photo in this conversation"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GroveTheme.softAccent,
                    in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    reusedPhotoCount > 1
                        ? "Ari will compare your two most recent photos"
                        : "Ari will use your earlier photo"
                )
                .accessibilityIdentifier("botanistReusedPhotoContext")
            }

            // One capsule: the photo disc, the reply and the ink send disc.
            // A long reply grows the bar upwards; the discs stay on its floor.
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Group {
                        if isPreparingPhoto {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: hasAttachedPhoto ? "photo.fill" : "photo.badge.plus")
                                .font(.system(size: 16, weight: .medium))
                        }
                    }
                    .foregroundStyle(hasAttachedPhoto ? GroveTheme.onAccent : GroveTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(
                        hasAttachedPhoto ? GroveTheme.accent : GroveTheme.secondarySurface,
                        in: Circle()
                    )
                }
                .buttonStyle(GrovePressStyle())
                .disabled(isAnswering || isLoadingPhoto)
                .accessibilityLabel(photoDraft == nil ? "Attach a photo" : "Replace attached photo")
                .accessibilityIdentifier("botanistPhotoPicker")

                TextField(composerPrompt, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("botanistComposer")
                    .font(.body)
                    .foregroundStyle(GroveTheme.ink)
                    .lineLimit(1...6)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                    .submitLabel(.send)
                    .onSubmit(sendDraft)

                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(GroveTheme.background)
                        .frame(width: 44, height: 44)
                        .background(GroveTheme.ink.opacity(canSend ? 1 : 0.28), in: Circle())
                }
                .buttonStyle(GrovePressStyle())
                .disabled(!canSend)
                .accessibilityLabel("Send question")
                .accessibilityIdentifier("botanistSend")
            }
            .padding(6)
            .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                    .strokeBorder(GroveTheme.separator, lineWidth: 1)
            }
            .animation(GroveMotion.snap, value: draft)
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > AskSession.maxQuestionCharacters {
                Text("\(AskSession.maxQuestionCharacters.formatted()) characters maximum.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroveTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("botanistQuestionLimit")
            }
            if let photoError {
                Text(photoError)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroveTheme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("botanistPhotoError")
            }

            Text(AskAllowance.aiDisclosure)
                .font(.caption2)
                .foregroundStyle(GroveTheme.subtleInk)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("askAIDisclosure")
        }
        // The one docked bar treatment, like every other committing action in
        // the app. This was the last screen still dissolving content into a
        // `.bar` material instead of the canvas.
        .groveActionBar()
    }

    private var composerPrompt: String {
        if isConversationEmpty {
            return plant.map { "Ask Ari about \($0.nickname)" } ?? "Ask Ari about your grove"
        }
        return "Reply"
    }

    // MARK: Actions

    private func sendDraft() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let photoData = photoDraft?.data
        draft = ""
        photoDraft = nil
        photoError = nil
        Task { await perform(question, photoData: photoData) }
    }

    private func retry() {
        guard let question = ask.unansweredQuestion(in: threadID) else {
            ask.clearFailure(in: threadID)
            return
        }
        Task { await perform(question) }
    }

    private func perform(_ question: String, photoData: Data? = nil) async {
        let plantID = thread?.plantID
        let result = await ask.ask(
            question,
            in: threadID,
            plantID: plantID,
            context: askContext(store: store, plantID: plantID, weather: weather),
            photoData: photoData,
            hasPremium: premium.isUnmetered
        )
        switch result.outcome {
        case .answered:
            // An answered question is the day's learning: it tends the
            // plant-safe streak and today's learn quest.
            if let earned = store.recordBotanistAnswer() {
                Haptics.celebrate()
                withAnimation(GroveMotion.celebrate) { reward = earned }
            } else {
                Haptics.success()
            }
        case .needsPremium:
            // The safety-only probe rejected a routine question before doing
            // paid work. Keep the user's words and selected photo ready so a
            // purchase does not make them reconstruct the fourth question.
            draft = question
            if let photoData, let preview = UIImage(data: photoData) {
                photoDraft = BotanistPhotoDraft(data: photoData, preview: preview)
            }
            Haptics.warning()
            paywallReason = .limitReached
        case .failed:
            // Shown inline by `FailureNotice`, with the question kept for retry.
            Haptics.warning()
        }
    }

    private func loadPhoto(from item: PhotosPickerItem) async {
        isLoadingPhoto = true
        photoError = nil
        defer {
            isLoadingPhoto = false
            selectedPhoto = nil
        }

        do {
            guard let sourceData = try await item.loadTransferable(type: Data.self),
                  let sourceImage = UIImage(data: sourceData) else {
                throw ScanMediaError.invalidImage
            }
            let prepared = sourceImage.preparedForPlantAnalysis()
            guard let payload = prepared.boundedPlantAnalysisJPEG(
                maximumBytes: AskSession.maxPhotoBytes
            ) else {
                throw ScanMediaError.invalidImage
            }
            Haptics.complete()
            withAnimation(GroveMotion.reveal) {
                photoDraft = BotanistPhotoDraft(data: payload.data, preview: payload.image)
            }
        } catch is CancellationError {
            return
        } catch {
            Haptics.error()
            // System errors name codecs and file paths; the user only needs
            // to know this photo won't work and what to do instead.
            photoError = "That photo couldn't be opened. Try another photo."
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(GroveMotion.settle) {
            if isAnswering {
                proxy.scrollTo(Self.thinkingAnchor, anchor: .bottom)
            } else if let last = thread?.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    /// VoiceOver users hear the answer arrive without leaving the composer.
    /// Only the answer this view watched begin is announced, so opening a
    /// conversation that finished answering elsewhere stays quiet.
    private func announceAnswerIfNeeded() {
        guard UIAccessibility.isVoiceOverRunning else { return }
        if let failure = ask.failureMessage(in: threadID) {
            AccessibilityNotification.Announcement("Ari couldn't answer. \(failure)").post()
            return
        }
        guard let answer = thread?.messages.last, answer.role == .botanist else { return }
        let preview = String(answer.text.prefix(160))
        AccessibilityNotification.Announcement("Ari answered. \(preview)").post()
    }
}

/// The conversation's header: the plant's photo, its name, and who is
/// answering from how much of its record.
private struct AskThreadTitle: View {
    let plant: Plant?
    let subtitle: String

    private static let size: CGFloat = 34

    var body: some View {
        HStack(spacing: 10) {
            if let plant {
                PlantThumbnail(plant: plant, height: Self.size, maxDimension: 140)
                    .frame(width: Self.size, height: Self.size)
                    .clipShape(RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
            } else {
                AskWholeGroveMark(size: Self.size)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(plant?.nickname ?? "Your grove")
                    .font(.headline)
                    .foregroundStyle(GroveTheme.ink)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The visible handoff from a plant page into its conversation.
///
/// A line of explanatory copy made the grounding technically true but visually
/// abstract. Keeping the latest portrait beside the plant's live status makes
/// the subject unmistakable, while the record summary is precise about the
/// context the botanist can actually use.
private struct BotanistPlantContextCard: View {
    @Environment(GroveStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let plant: Plant

    private var observations: [PlantObservation] {
        store.observations(for: plant.id)
    }

    private var loggedCareCount: Int {
        store.tasks.filter {
            $0.plantID == plant.id && $0.isCompleted && $0.kind != .checkIn
        }.count
    }

    private var hasPhoto: Bool {
        store.latestPhotoURL(for: plant.id) != nil
    }

    private var recordSummary: String {
        var parts: [String] = []
        if !observations.isEmpty {
            parts.append("\(observations.count) check-in\(observations.count == 1 ? "" : "s")")
        }
        if loggedCareCount > 0 {
            parts.append("\(loggedCareCount) care entr\(loggedCareCount == 1 ? "y" : "ies")")
        }
        return parts.isEmpty
            ? "Current health and care plan"
            : parts.joined(separator: " · ")
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 14) {
                    portrait
                        .frame(maxWidth: .infinity)
                        .frame(height: 168)
                    details
                }
            } else {
                HStack(alignment: .center, spacing: 14) {
                    portrait
                        .frame(width: 98, height: 112)
                    details
                }
            }
        }
        .padding(12)
        .background(
            GroveTheme.surface,
            in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
        )
        .groveEdgeLight(radius: GroveTheme.cardRadius)
        .groveShadow(.floating)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Asking Ari about \(plant.nickname), \(plant.species). "
                + "\(plant.healthBand.title), health \(plant.healthScore) percent. "
                + "Using \(recordSummary)."
        )
    }

    private var portrait: some View {
        PlantThumbnail(plant: plant, height: dynamicTypeSize.isAccessibilitySize ? 168 : 112, maxDimension: 420)
            .clipShape(RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                Text(hasPhoto ? "Latest photo" : "Portrait")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.52), in: Capsule())
                    .padding(8)
            }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            GroveEyebrow(text: "Asking Ari about", color: GroveTheme.accentStrong)

            VStack(alignment: .leading, spacing: 2) {
                Text(plant.nickname)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)
                Text(plant.species)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(plant.healthBand.color)
                    .frame(width: 7, height: 7)
                Text("\(plant.healthBand.shortTitle) · \(plant.healthScore)%")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
            }

            Label(recordSummary, systemImage: "doc.text.magnifyingglass")
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Opens a fresh conversation about one plant.
///
/// The destination always carries the plant id and may carry an editable
/// starter from a specific surface, such as the latest scan summary. The thread
/// is minted here on first appearance, keeping either entry point a single push
/// without making callers create empty conversations themselves.
struct AskAboutPlantView: View {
    let plantID: UUID
    let initialDraft: String

    @Environment(AskSession.self) private var ask
    @State private var threadID: UUID?

    init(plantID: UUID, initialDraft: String = "") {
        self.plantID = plantID
        self.initialDraft = initialDraft
    }

    var body: some View {
        Group {
            if let threadID {
                AskThreadView(threadID: threadID, initialDraft: initialDraft)
            } else {
                Color.clear.groveBackground()
            }
        }
        .task {
            if threadID == nil {
                threadID = ask.startDraftThread(plantID: plantID).id
            }
        }
    }
}

private struct MessageBubble: View {
    let message: BotanistMessage
    let threadID: UUID

    @Environment(AskSession.self) private var ask
    @State private var isSavingOutcome = false
    @State private var outcomeFailed = false

    private var isUser: Bool { message.role == .user }

    /// The botanist writes markdown; the user typed plain text and would be
    /// startled to see their own asterisks reinterpreted.
    private var displayText: AttributedString {
        isUser ? AttributedString(message.text) : BotanistFormatting.attributed(message.text)
    }

    var body: some View {
        Group {
            if isUser {
                userTurn
            } else {
                ariTurn
            }
        }
        .accessibilityElement(children: .combine)
        // Spoken from the stripped text: VoiceOver reading "asterisk asterisk
        // overwatering" is the same defect heard rather than seen.
        .accessibilityLabel(
            "\(isUser ? "You asked" : "Ari"): "
            + "\(message.photoURL == nil ? "" : "Photo attached. ")"
            + "\(isUser ? message.text : BotanistFormatting.plain(message.text))"
        )
        .accessibilityIdentifier(isUser ? "botanistUserMessage" : "botanistAnswer")
    }

    /// The user's words: any photo above, then an ink bubble whose tail
    /// corner points back at the field they came from.
    private var userTurn: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let photoURL = message.photoURL {
                BotanistMessagePhoto(url: photoURL)
            }
            Text(displayText)
                .font(.body)
                .foregroundStyle(GroveTheme.background)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    GroveTheme.ink,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 22,
                        bottomLeadingRadius: 22,
                        bottomTrailingRadius: 6,
                        topTrailingRadius: 22,
                        style: .continuous
                    )
                )
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 44)
    }

    /// Ari's answer: a small face and plain text, no bubble. The answer is the
    /// page, so it reads like one.
    private var ariTurn: some View {
        HStack(alignment: .top, spacing: 10) {
            AriAvatar(size: 32)
            VStack(alignment: .leading, spacing: 14) {
                if let photoURL = message.photoURL {
                    BotanistMessagePhoto(url: photoURL)
                }
                Text(displayText)
                    .font(.body)
                    .lineSpacing(4)
                    .foregroundStyle(GroveTheme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if message.adviceID != nil {
                    responseDetails
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Where the answer was checked, as one small line with the publishers
    /// as links.
    private var sourcesLine: AttributedString? {
        guard let sources = message.sources, !sources.isEmpty else { return nil }
        var seen = Set<String>()
        let unique = sources.filter { seen.insert($0.publisher).inserted }
        let isChecked = message.verification == "approve" || message.verification == "revise"
        var line = AttributedString(isChecked ? "Checked against " : "Sources: ")
        for (index, source) in unique.enumerated() {
            var part = AttributedString(source.publisher)
            part.link = source.url
            line += part
            if index < unique.count - 1 {
                line += AttributedString(", ")
            }
        }
        line += AttributedString(".")
        return line
    }

    private var isFollowUpDue: Bool {
        guard let followUpAt = message.followUpAt else { return false }
        return followUpAt <= .now
    }

    private var hasPlantOutcome: Bool {
        message.recordedOutcome == .improved
            || message.recordedOutcome == .same
            || message.recordedOutcome == .worse
    }

    private var responseDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let sourcesLine {
                Text(sourcesLine)
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .tint(GroveTheme.accentStrong)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if outcomeFailed {
                Text("That feedback didn’t save. Try again.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroveTheme.warning)
            }

            if isFollowUpDue, !hasPlantOutcome {
                Text("How does the plant look now?")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroveTheme.mutedInk)
                HStack(spacing: 12) {
                    outcomeButton("Better", symbol: "arrow.up", outcome: .improved)
                    outcomeButton("Same", symbol: "equal", outcome: .same)
                    outcomeButton("Worse", symbol: "arrow.down", outcome: .worse)
                }
            } else if message.recordedOutcome == nil {
                HStack(spacing: 12) {
                    outcomeButton("Helpful", symbol: "hand.thumbsup", outcome: .helpful)
                    outcomeButton("Not helpful", symbol: "hand.thumbsdown", outcome: .notHelpful)
                }
            } else {
                Label("Feedback saved", systemImage: "checkmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroveTheme.mutedInk)
            }
        }
    }

    private func outcomeButton(
        _ title: String,
        symbol: String,
        outcome: BotanistOutcome
    ) -> some View {
        Button {
            guard !isSavingOutcome else { return }
            isSavingOutcome = true
            outcomeFailed = false
            Task {
                let saved = await ask.recordOutcome(outcome, for: message.id, in: threadID)
                isSavingOutcome = false
                outcomeFailed = !saved
                if saved { Haptics.success() } else { Haptics.warning() }
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GroveTheme.accentStrong)
                // The label stays small; the target does not.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSavingOutcome)
    }
}

private struct BotanistMessagePhoto: View {
    let url: URL

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    GroveTheme.softAccent
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(GroveTheme.subtleInk)
                }
            }
        }
        .frame(width: 200, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .task(id: url) {
            image = await GroveImageLoader.downsampledImage(at: url, maxDimension: 800)
        }
        .accessibilityHidden(true)
    }
}

/// The wait, which is the one moment the botanist is present and silent.
///
/// Ari breathes rather than blinking dots: one slow breath every four seconds,
/// the pace Headspace uses for its breathing orb, so the wait has a rhythm
/// instead of a tick. The line beside Ari names what the answer is built
/// from, then admits a long wait. Ari never narrates its own process
/// (VOICE.md), so there is no "checking sources" or "thinking it through"
/// between the two. It advances slowly, so a fast answer only ever shows the
/// first line.
private struct ThinkingBubble: View {
    /// The plant this conversation is about, so the wait can name it. Nil for a
    /// whole-grove question.
    var plantName: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isInhaling = false
    @State private var stage = 0

    /// Deliberately unhurried, and the last one has no successor: past
    /// fifteen seconds the honest thing is to admit the wait.
    private var lines: [String] {
        [
            plantName.map { "Looking over \($0)'s check-ins" } ?? "Looking over your grove",
            "Still going. This one needs a minute"
        ]
    }

    private var line: String { lines[min(stage, lines.count - 1)] }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AriAvatar(size: 32)
                // The breath lives behind the avatar and never moves the
                // layout: a soft green field swells out and draws back in.
                .background {
                    Circle()
                        .fill(GroveTheme.accent.opacity(0.16))
                        .scaleEffect(isInhaling ? 1.5 : 1)
                }
                .scaleEffect(isInhaling ? 1.04 : 0.97)
            Text(line)
                .font(.footnote)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
                // Identity changes with the line, so the stage advance
                // cross-fades rather than snapping to new words.
                .id(line)
                .transition(.opacity)
                .padding(.top, 7)
            Spacer(minLength: 12)
        }
        .onAppear {
            // With Reduce Motion on, Ari sits still and the words alone carry
            // the wait.
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                isInhaling = true
            }
        }
        .task {
            // 15s. Long enough that a typical answer never shows more than
            // the opening line.
            for (next, delay) in [(1, 15.0)] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.35)) { stage = next }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ari: \(line)")
    }
}

private struct FailureNotice: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(GroveTheme.warning)
                Text(message)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Button(action: onRetry) {
                Text("Try again")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(GroveTheme.accentStrong)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                .stroke(GroveTheme.warning.opacity(0.4), lineWidth: 1)
        }
        .accessibilityIdentifier("botanistFailure")
    }
}

// MARK: - Premium wall

/// The Premium upsell shown either proactively or when the allowance is spent.
///
/// It follows `GrovePremiumStore`'s honesty rule: when there is no product to
/// sell — App Store Connect not configured, or the store unreachable — it says
/// so and lifts the limit rather than advertising a price it cannot charge or
/// dead-ending a user mid-question.
struct AskPaywallSheet: View {
    /// Why this sheet is open. Every line of its copy was written for someone
    /// who had just hit the daily limit; opened from Settings by a browser who
    /// has asked nothing today, "you've used today's questions" is simply
    /// untrue, and an upsell that opens with a false statement about the user
    /// is worse than no upsell.
    enum Reason: Hashable, Identifiable {
        /// The day's free questions are spent and a question is waiting.
        case limitReached
        /// The user opened an upgrade affordance before a question was blocked.
        case browsing
        /// Opened from Settings: nothing was asked, so nothing about questions
        /// is assumed.
        case settings
        /// The user tapped a locked premium profile mascot.
        case profileAvatar

        var id: Self { self }
    }

    let reason: Reason

    @Environment(GrovePremiumStore.self) private var premium
    @Environment(AskSession.self) private var ask
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPlan: GrovePremiumStore.Plan = .yearly
    @State private var isWorking = false
    @State private var failure: String?
    /// A neutral outcome, such as a purchase waiting on Ask to Buy. Not an
    /// error, so it is not drawn in the error colour.
    @State private var notice: String?

    @ScaledMetric(relativeTo: .footnote) private var benefitIconWidth: CGFloat = 24
    @ScaledMetric(relativeTo: .footnote) private var benefitIconSpacing: CGFloat = 10

    private var isPurchasable: Bool {
        premium.displayPrice(for: .yearly) != nil || premium.displayPrice(for: .monthly) != nil
    }

    /// The App Store never answered, so whether there is anything to sell is
    /// unknown. Distinct from "nothing on sale": an unreachable store must not
    /// be read as a free pass, or being offline would be the cheapest way past
    /// the only paywall in the app.
    private var isStoreUnreachable: Bool {
        !premium.didLoadCatalogue
    }

    /// The plan the purchase action uses. When the catalogue resolves without
    /// the selected plan, fall back to one that is actually for sale rather
    /// than leaving the button pointed at something that cannot be bought.
    private var effectivePlan: GrovePremiumStore.Plan {
        if premium.displayPrice(for: selectedPlan) != nil { return selectedPlan }
        return GrovePremiumStore.Plan.allCases.first { premium.displayPrice(for: $0) != nil } ?? selectedPlan
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if reason == .profileAvatar {
                        GroveSymbolTile(symbol: "sparkles", size: 56)
                    } else {
                        GroveArtworkTile(asset: "GroveBotanist", size: 56)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        GroveDisplayHeading(text: heading, style: .heading)
                        Text(paywallSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(GroveTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Only what Premium actually gates, the same three lines
                    // every paywall lists, led by the one that opened this.
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(PremiumBenefit.all(leading: reason == .profileAvatar ? .mascots : .questions)) { item in
                            benefit(item.text, symbol: item.symbol)
                        }
                    }

                    if isPurchasable {
                        VStack(spacing: 10) {
                            ForEach(GrovePremiumStore.Plan.allCases.filter { premium.displayPrice(for: $0) != nil }, id: \.self) { plan in
                                planRow(plan)
                            }
                        }
                    }

                    if let failure {
                        Text(failure)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(GroveTheme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let notice {
                        Text(notice)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(GroveTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    GroveCTAButton(
                        title: primaryActionTitle,
                        systemImage: isWorking ? "hourglass" : "arrow.right"
                    ) {
                        Task { await primaryAction() }
                    }
                    .disabled(isWorking)

                    // A visible way back. The swipe and the toolbar still work,
                    // but someone who hit a limit should not need to hunt for a
                    // gesture to leave.
                    Button(PremiumTerms.notNowTitle) { dismiss() }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GroveTheme.mutedInk)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                        .padding(.top, 4)
                        .disabled(isWorking)
                        .accessibilityIdentifier("askPaywallNotNow")

                    if isPurchasable {
                        // 3.1.2: a button that can start a trial sits next to
                        // what the trial turns into and how it renews.
                        if let renewal = PremiumTerms.renewalNote(premium, plan: effectivePlan) {
                            Text(renewal)
                                .font(.footnote)
                                .foregroundStyle(GroveTheme.mutedInk)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity)
                        }
                    }

                    // Restore and the legal links are not part of "something is
                    // for sale": an unreachable or unsold store still owes a
                    // subscriber a way to restore and everyone the terms.
                    Button("Restore purchases") {
                        Task { await restore() }
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GroveTheme.mutedInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(isWorking)

                    // App Review 3.1.2 requires a functional link to the
                    // terms and the privacy policy on every screen that
                    // sells a subscription, not just the one in onboarding.
                    OnboardingLegalFooter(tint: GroveTheme.mutedInk)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, GroveTheme.pageBottomPadding)
            }
            .groveBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(GroveTheme.mutedInk)
                }
            }
        }
        .task { await premium.load() }
    }

    private func benefit(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: benefitIconSpacing) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(GroveTheme.accent)
                .frame(width: benefitIconWidth, alignment: .leading)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var heading: String {
        switch reason {
        case .profileAvatar: "Premium mascots"
        case .settings: "Grove Premium"
        case .limitReached, .browsing: "Keep asking Ari"
        }
    }

    private func planRow(_ plan: GrovePremiumStore.Plan) -> some View {
        let isSelected = effectivePlan == plan
        // The saving is computed from the two live prices, so the badge is a
        // fact rather than the word "Best value" asserted over whatever the
        // catalogue happens to hold. Nil when the annual is not actually
        // cheaper, which is the only honest thing to show in that case.
        let caption = plan == .yearly ? premium.yearlySavingsLabel : nil
        // The trial leads the row when this Apple account can redeem one, so
        // the price under the button is never the first a user hears of it.
        let trial = PremiumTerms.trialLine(premium, plan: plan)
        // 3.1.2 again: the billing period has to be legible next to the price.
        // "Yearly / $34.99" leaves the duration to be inferred from the title.
        let period = plan == .yearly ? "per year" : "per month"
        return Button {
            Haptics.selection()
            failure = nil
            notice = nil
            selectedPlan = plan
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSelected ? GroveTheme.accent : GroveTheme.subtleInk)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan == .yearly ? "Yearly" : "Monthly")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(GroveTheme.ink)
                    if let trial {
                        Text(trial)
                            .font(.caption)
                            .foregroundStyle(GroveTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(GroveTheme.accentStrong)
                    }
                    if plan == .yearly, let weekly = PremiumTerms.weeklyLine(premium, plan: plan) {
                        Text(weekly)
                            .font(.caption)
                            .foregroundStyle(GroveTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(premium.displayPrice(for: plan) ?? (premium.didLoadCatalogue ? "Unavailable" : "Loading…"))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(GroveTheme.ink)
                    Text(period)
                        .font(.caption2)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
            }
            .padding(14)
            .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                    .stroke(isSelected ? GroveTheme.accent : GroveTheme.separator, lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(GroveCardPressStyle(scale: 0.99, haptics: false))
    }

    /// When the free questions come back, said the way a person would say it.
    ///
    /// This used to read "They come back tomorrow", which was true only for a
    /// user whose day happened to line up with the gateway's. The allowance
    /// resets on the UTC day, so in New Zealand it returns around lunchtime and
    /// "tomorrow" was wrong by half a day, in the direction that makes someone
    /// pay for something they were about to get for free.
    static func resetSentence(at date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        // Everything is measured and rendered in the given calendar's zone.
        // `isDateInTomorrow` would have read the system clock instead of `now`,
        // which is exactly the kind of hidden device dependency that put the
        // wrong reset on this screen in the first place.
        let time = date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone)
        )
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        if days <= 0 { return "They come back at \(time)." }
        if days == 1 { return "They come back tomorrow at \(time)." }
        let weekday = date.formatted(
            Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.wide)
        )
        return "They come back on \(weekday) at \(time)."
    }

    private var paywallSubtitle: String {
        Self.subtitle(
            reason: reason,
            remaining: ask.remainingFreeAsks(hasPremium: false),
            isPurchasable: isPurchasable,
            isStoreUnreachable: isStoreUnreachable,
            isUnmetered: premium.isUnmetered,
            resetAt: ask.freeAsksResetAt
        )
    }

    /// The sheet's opening sentence, kept pure so the allowance and safety
    /// wording can be asserted without building the view or its environment.
    static func subtitle(
        reason: Reason,
        remaining: Int,
        isPurchasable: Bool,
        isStoreUnreachable: Bool,
        isUnmetered: Bool,
        resetAt: Date
    ) -> String {
        if reason == .profileAvatar {
            if isPurchasable {
                return "Grove Premium adds \(AvatarView.premiumImageNames.count) plant mascots to choose from."
            }
            if isStoreUnreachable {
                return "Grove couldn't reach the App Store to check Premium availability."
            }
            return "These plant mascots come with Grove Premium."
        }
        // A proactive upgrade can be opened from Ask or Settings at any point
        // in the day, so its opening sentence reports the allowance that is
        // actually left instead of borrowing the exhausted-state copy.
        // Nothing is metered while Premium isn't on sale, so there is no
        // allowance to report, and counting one beside "there's no daily
        // limit" contradicted itself.
        let allowance: String = if isUnmetered {
            ""
        } else {
            switch reason {
            case .limitReached: "You've used today's \(AskSession.freeAsksPerDay) free questions."
            case .browsing, .settings: Self.allowanceSentence(remaining: remaining)
            case .profileAvatar: ""
            }
        }
        // The reset has to be in the purchasable branch too. It was written for
        // the store-unreachable case only — so the one sentence that turns a
        // wall into a boundary was shown exclusively to users who could not be
        // charged, and the paying case read as "buy or stop", usually while the
        // user was worried about a specific plant. A proactive upgrade only
        // mentions the reset if the live allowance is also exhausted.
        let allowanceIsSpent = reason == .limitReached || remaining == 0
        let reset = allowanceIsSpent ? " \(Self.resetSentence(at: resetAt))" : ""
        // The gateway still answers a recognised emergency for free, so a
        // parent whose child has just chewed a leaf must not read "used up"
        // and stop. Said once, beside the allowance, before the upsell.
        let safety = allowanceIsSpent ? " \(AskAllowance.safetyStillAnswered)" : ""
        if isPurchasable {
            return "\(allowance)\(reset)\(safety) Premium gives you up to \(AskSession.premiumAsksPerDay) questions a day."
        }
        if isStoreUnreachable {
            return "\(allowance)\(reset)\(safety) Grove couldn't reach the App Store to check what's available."
        }
        // "The rest are on us" only means anything to someone who has run out.
        let unsold = reason == .limitReached
            ? "\(allowance)\(safety) Grove Premium isn't on sale yet, so the rest are on us."
            : "\(allowance)\(safety) Grove Premium isn't on sale yet, so there's no daily limit in the meantime."
        return unsold.trimmingCharacters(in: .whitespaces)
    }

    static func allowanceSentence(remaining: Int) -> String {
        switch max(0, min(AskSession.freeAsksPerDay, remaining)) {
        case 0: "You've used today's \(AskSession.freeAsksPerDay) free questions."
        case 1: "You have 1 free question left today."
        case let count: "You have \(count) free questions left today."
        }
    }

    private var primaryActionTitle: String {
        if isPurchasable {
            if let trial = PremiumTerms.trialButtonTitle(premium, plan: effectivePlan) { return trial }
            return PremiumTerms.subscribeTitle(premium, plan: effectivePlan)
        }
        if isStoreUnreachable { return "Try again" }
        if reason == .profileAvatar { return "Close" }
        return reason == .limitReached ? "Carry on asking" : "Got it"
    }

    private func primaryAction() async {
        failure = nil
        notice = nil
        guard isPurchasable else {
            if isStoreUnreachable {
                // Retry the catalogue rather than lifting the limit. An
                // unreachable store is not evidence that nothing is for sale.
                isWorking = true
                failure = nil
                await premium.load()
                isWorking = false
                if isStoreUnreachable {
                    failure = "Still can't reach the App Store. Check your connection and try again."
                }
                return
            }
            if reason == .profileAvatar {
                dismiss()
                return
            }
            // The store answered and had nothing to sell: the limit is lifted
            // for the session rather than holding a user hostage to a product
            // that does not exist.
            premium.grantUnsoldPremium()
            dismiss()
            return
        }
        isWorking = true
        defer { isWorking = false }
        switch await premium.purchase(effectivePlan) {
        case .unlocked:
            Haptics.celebrate()
            dismiss()
        case .pending:
            // Ask to Buy: nothing is charged yet and nothing is unlocked, so
            // closing silently left the user guessing which of those it was.
            notice = PremiumTerms.pendingMessage
        case .cancelled:
            break
        case .unavailable:
            // Lifts the limit only if the whole catalogue is empty. When one
            // plan is missing, the sheet stays and says so.
            premium.grantUnsoldPremium()
            if premium.hasPremium {
                dismiss()
            } else {
                failure = PremiumTerms.unavailableMessage
            }
        case .failed(let message):
            failure = message
        }
    }

    private func restore() async {
        failure = nil
        notice = nil
        isWorking = true
        defer { isWorking = false }
        switch await premium.restorePurchases() {
        case .restored:
            Haptics.celebrate()
            dismiss()
        case .notFound:
            failure = PremiumTerms.restoreNotFoundMessage
        case .failed(let message):
            failure = message
        }
    }
}

#Preview("Ask") {
    AppDestinationsPreviewHost { AskView() }
        .environment(GroveStore())
        .environment(AskSession())
        .environment(GrovePremiumStore())
        .environment(IntentRouter.shared)
}

#Preview("Conversation") {
    let session = AskSession()
    let threadID = session.queue("Why is my monstera drooping?", plantID: nil)
    return NavigationStack { AskThreadView(threadID: threadID) }
        .environment(GroveStore())
        .environment(session)
        .environment(GrovePremiumStore())
        .environment(IntentRouter.shared)
        .environment(WeatherService())
}

#Preview("Plant conversation") {
    let store = GroveStore(persistenceEnabled: false)
    let session = AskSession()
    let plant = store.plants[0]
    let threadID = session.startDraftThread(plantID: plant.id).id
    return NavigationStack { AskThreadView(threadID: threadID) }
        .environment(store)
        .environment(session)
        .environment(GrovePremiumStore())
        .environment(IntentRouter.shared)
        .environment(WeatherService())
}
