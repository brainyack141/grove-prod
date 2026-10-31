import SwiftUI
import UIKit

/// Condition, the next useful action, and evidence of progress for this plant.
/// Once the inline action scrolls away, the footer preserves the same route.
struct PlantDetailView: View {
    @Environment(GroveStore.self) private var store
    @Environment(SyncEngine.self) private var syncEngine
    @Environment(ConnectivityMonitor.self) private var connectivity
    @Environment(GroveToastCenter.self) private var toasts: GroveToastCenter?
    @Environment(\.dismiss) private var dismiss
    let plantID: UUID

    @Environment(NotificationService.self) private var notifications
    @Environment(AskSession.self) private var ask
    @Environment(GrovePremiumStore.self) private var premium
    @Environment(\.openURL) private var openURL
    @AppStorage(GroveDefaults.careReminders) private var careReminders = true
    @State private var showingReminderPrimer = false
    @State private var requestingReminder = false
    @State private var reminderError: String?
    @State private var showingRemoveConfirmation = false
    @State private var plantToShare: Plant?
    /// A rendered Living Record film waiting for the share sheet.
    @State private var plantToShareRecord: GroveSharedFile?
    @State private var isCreatingCollection = false
    /// Set when a watering was refused because there was a recent one, which
    /// raises the check-the-soil-first prompt rather than losing the tap.
    @State private var recentWatering: RecentWatering?
    /// True once the hero has scrolled far enough that the navigation bar has
    /// to carry the plant's name itself.
    @State private var titleIsCollapsed = false

    var body: some View {
        if let plant = store.plant(id: plantID) {
            page(for: plant)
        } else {
            GroveEmptyState(
                scene: .vanished,
                title: "Plant not found",
                message: "It was probably removed from your grove, here or on another device."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .groveBackground()
        }
    }

    private func enableReminder() {
        guard !requestingReminder else { return }
        if notifications.authorization == .denied {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            return
        }
        requestingReminder = true
        reminderError = nil
        Task {
            await notifications.requestAuthorization()
            OnboardingAnalytics.notificationsDecision(.system(authorization: notifications.authorization))
            if notifications.authorization.canSchedule {
                careReminders = true
                showingReminderPrimer = false
            } else {
                reminderError = "Notifications are off. You can enable them in Settings whenever you're ready."
            }
            requestingReminder = false
        }
    }

    // MARK: - Page

    private func page(for plant: Plant) -> some View {
        let dueCare = store.pendingTasks.filter { $0.plantID == plant.id }
        let pendingCheckIn = dueCare
            .filter { $0.kind == .checkIn && !$0.isSittingTask }
            .min { $0.dueDate < $1.dueDate }
        let safety = PlantSafety(plant: plant)

        // The chrome is a sibling of the scroll view rather than a navigation
        // bar. A `ZStack` keeps its own safe area while the scroll view inside
        // ignores the top one, so the photo starts at the physical top of the
        // screen and the chips still land under the status bar.
        return ZStack(alignment: .top) {
            PlantBoardPage(plant: plant, collapsed: $titleIsCollapsed, onWater: { log(.water, for: plant) }) {
                // Ahead of everything else on the sheet, because it is the only
                // thing on the page that can hurt somebody.
                if safety.cautionLevel != .none {
                    PlantSafetyAlert(plant: plant, safety: safety)
                }
                if PlantIdentityState.needsResolving(plant) {
                    PlantIdentityCard(plant: plant)
                }
                if !plant.effectiveLifecycleState.receivesCareReminders {
                    PlantLifecycleBanner(plant: plant)
                }
            }

            PlantPageChrome(
                title: plant.nickname,
                collapsed: titleIsCollapsed,
                onBack: { dismiss() },
                menu: { menuContents(for: plant) }
            )
        }
        .background(GroveTheme.surface.ignoresSafeArea())
        .groveStatusBar(titleIsCollapsed ? .darkContent : .lightContent)
        .task { OnboardingAnalytics.plantPageViewed() }
        .task { await premium.load() }
        .safeAreaInset(edge: .bottom, spacing: 0) { dockedActionBar(for: plant, task: pendingCheckIn) }
        .sheet(isPresented: $showingReminderPrimer) {
            VStack(spacing: 0) {
                OnboardingNotificationPrimerView(
                    plant: plant,
                    task: OnboardingReminderPreview.firstTask(for: plant, in: store.tasks),
                    reminderHour: UserDefaults.standard.object(forKey: GroveDefaults.reminderHour) as? Int ?? NotificationService.reminderHour,
                    isRequesting: requestingReminder,
                    enableTitle: notifications.authorization == .denied ? "Open Settings" : "Turn on reminders",
                    onEnable: { enableReminder() },
                    onSkip: { showingReminderPrimer = false }
                )
                if let reminderError {
                    Text(reminderError).font(.footnote).foregroundStyle(GroveTheme.danger).padding()
                }
            }
        }
        .navigationTitle(plant.nickname)
        .navigationBarTitleDisplayMode(.inline)
        // The page draws its own chrome. iOS 26 renders navigation bar items as
        // standard glass buttons and discards the background on a custom label,
        // so the scrimmed chips this hero needs came out as the same pale discs
        // as every other bar in the app — and the bar itself kept painting cream
        // across the top of the photo whatever visibility it was handed.
        .groveHidesNavigationBar()
        // The tab bar is hidden here, but never by this view. `AppShellChromePolicy`
        // owns that: it hides the bar for every drill-in and restores it on pop.
        // A destination-level `.toolbar(.hidden, for: .tabBar)` outlives the pop
        // animation and can win the race against the shell's `.visible`, which is
        // exactly how the bar used to go missing after leaving a plant page.
        .confirmationDialog(
            "Delete \(plant.nickname) from your grove?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete plant", role: .destructive) {
                // A deletion that cannot be undone should land as a
                // warning, not as the same tap as everything else.
                Haptics.warning()
                delete(plant)
            }
        } message: {
            Text("Every check-in, photo, care task and note for \(plant.nickname) is deleted on every synced device. There is no undo.")
        }
        .sheet(item: $plantToShare) { plant in
            PlantShareSheet(plant: plant)
        }
        .sheet(item: $plantToShareRecord) { record in
            GroveShareSheet(items: [record.url])
        }
        .sheet(isPresented: $isCreatingCollection) {
            CreateCollectionView(preselecting: [plant.id])
        }
        .confirmationDialog(
            recentWatering.map { "You watered \(plant.nickname) \($0.phrase)." } ?? "",
            isPresented: Binding(
                get: { recentWatering != nil },
                set: { if !$0 { recentWatering = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("It's dry, log watering") {
                logVerifiedWatering(for: plant)
            }
            Button("It's still damp") {
                recentWatering = nil
            }
            Button("Cancel", role: .cancel) { recentWatering = nil }
        } message: {
            Text("Feel two knuckles into the soil. Water again only if it comes out dry.")
        }
    }

    /// A watering Grove declined to log twice, and how long ago the last one was.
    private struct RecentWatering: Identifiable {
        let plantID: UUID
        let loggedAt: Date

        var id: UUID { plantID }

        var phrase: String {
            let days = Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: loggedAt),
                to: Calendar.current.startOfDay(for: .now)
            ).day ?? 0
            switch days {
            case ..<1: return "today"
            case 1: return "yesterday"
            default: return "\(days) days ago"
            }
        }
    }

    /// How far back a check-in can be and still speak for the plant's state.
    /// Soil moisture recorded three months ago is history, not a reading.
    ///
    /// Shared by every block that claims to describe the plant *now*, so the
    /// page cannot hold two opinions about whether the same observation counts.
    static let stateWindowDays = 30

    /// The newest check-in still inside the state window, or nothing.
    static func liveObservation(in observations: [PlantObservation]) -> PlantObservation? {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -stateWindowDays,
            to: .now
        ) ?? .distantPast
        return observations.first { $0.createdAt >= cutoff }
    }

    /// Whether anything Grove holds still describes this plant as it is now.
    ///
    /// False is the interesting case: it means every block that speaks in the
    /// present tense is speaking about a plant nobody has looked at in a month,
    /// and should say so rather than reach for its most reassuring default.
    static func hasCurrentEvidence(plant: Plant, observations: [PlantObservation]) -> Bool {
        if liveObservation(in: observations) != nil { return true }
        // A placeholder score is not evidence. Without a look taken since, the
        // page must admit there is nothing to read rather than borrow it.
        if !plant.hasHealthReading { return false }
        // Never checked in: the adoption assessment is the only reading there
        // has ever been, and it speaks for the plant until the first check-in is
        // well past due.
        if observations.isEmpty, let assessedAt = plant.assessmentDate {
            let cutoff = Calendar.current.date(byAdding: .day, value: -stateWindowDays, to: .now) ?? .distantPast
            return assessedAt >= cutoff && assessedAt <= .now
        }
        // Legacy records predate `assessmentDate`; their due date is the only
        // remaining clock and stays a fallback rather than overruling a real
        // evidence timestamp.
        if observations.isEmpty { return plant.daysUntilCheckIn > -stateWindowDays }
        return false
    }

    /// The plant's neighbours in the grove. A collector moving plant to plant
    /// had only back-and-forth push-and-pop; a previous/next pair turns a
    /// forty-plant round into one pass. Ordering follows the grove list's own
    /// most-recent-first ordering so the page never disagrees with it.
    private var previousPlant: Plant? { neighbour(offset: -1) }
    private var nextPlant: Plant? { neighbour(offset: 1) }

    private func neighbour(offset: Int) -> Plant? {
        let ordered = store.plants
        guard let index = ordered.firstIndex(where: { $0.id == plantID }) else { return nil }
        let neighbourIndex = index + offset
        guard ordered.indices.contains(neighbourIndex) else { return nil }
        return ordered[neighbourIndex]
    }

    /// The docked bar preserves the page's primary route once the inline action
    /// scrolls away, and gives the one response a plant's page could not accept:
    /// "not tonight". Deferring a reminder had no home on this surface, so a
    /// commuter whose reminder arrived mid-journey could only complete it or
    /// ignore it — and ignoring it taught the app the reminder had been missed.
    /// Whether the docked bar is carrying this page's primary action.
    ///
    /// Read in two places on purpose: the bar itself, and the action card that
    /// must not draw a second copy of the same button directly above it.
    static func docksAction(plant: Plant, task: CareTask?, at now: Date = .now) -> Bool {
        guard plant.effectiveLifecycleState.receivesCareReminders else { return false }
        // `task` is the earliest *incomplete* check-in, which on the day a
        // plant is added is one scheduled a fortnight out. Docking on that
        // alone put a permanent "Check in" pill under a card that said the
        // next look was in 14 days, and offered to defer a task nobody had
        // been asked for yet: "Not tonight" moved it from a fortnight away to
        // tomorrow, which is the one direction a snooze must never go.
        if let task { return isDue(task, at: now) }
        // By day, like `isDue`: a check-in due today is due all day.
        let calendar = Calendar.current
        return calendar.startOfDay(for: plant.nextCheckIn) <= calendar.startOfDay(for: now)
    }

    @ViewBuilder
    private func dockedActionBar(for plant: Plant, task: CareTask?) -> some View {
        if Self.docksAction(plant: plant, task: task) {
            HStack(spacing: 10) {
                NavigationLink(value: AppRoute.checkIn(plant.id)) {
                    GroveInkLabel(title: "Check in", systemImage: "camera.fill")
                }
                .buttonStyle(GrovePressStyle())
                .accessibilityIdentifier("plantDockedCheckIn")

                if let task, Self.isDue(task) {
                    Button {
                        guard store.snooze(taskID: task.id, until: PlantSnooze.tomorrow, reason: PlantSnooze.label()) != nil else {
                            Haptics.error()
                            return
                        }
                        Haptics.tap()
                        toasts?.show("Moved \(plant.nickname)'s check-in to tomorrow", symbol: "moon.zzz.fill")
                    } label: {
                        Text(PlantSnooze.label())
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(GroveTheme.accentStrong)
                            .frame(minHeight: 48)
                            .padding(.horizontal, 16)
                    }
                    .buttonStyle(GrovePressStyle())
                    .accessibilityIdentifier("plantDockedSnooze")
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.vertical, 10)
            .groveActionBar()
        }
    }

    /// Whether a task has actually come due, by day rather than by instant: a
    /// check-in due at 9am is due all day, not overdue from 9:01.
    static func isDue(_ task: CareTask?, at now: Date = .now) -> Bool {
        guard let task, !task.isCompleted else { return false }
        let calendar = Calendar.current
        return calendar.startOfDay(for: task.dueDate) <= calendar.startOfDay(for: now)
    }

    enum PlantSnooze {
        /// Tomorrow morning, not "in 24 hours": a reminder deferred at 10pm
        /// should arrive with the next day, not that night. Set by the clock
        /// rather than by adding hours to midnight, so a daylight-saving
        /// change still lands at 9am.
        static var tomorrow: Date {
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: .now)
            guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { return .now }
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: next) ?? next
        }

        /// "Not tonight" only once it is evening; the bar shows all day.
        static func label(at now: Date = .now) -> String {
            Calendar.current.component(.hour, from: now) >= 17 ? "Not tonight" : "Remind me tomorrow"
        }
    }

    // MARK: - Chrome

    private func needsPersonalization(_ plant: Plant) -> Bool {
        let location = plant.location.trimmingCharacters(in: .whitespacesAndNewlines)
        return location.isEmpty || location == "Unassigned"
    }

    /// One-tap adoption lands here instead of in a setup form. The baseline is
    /// already safe; naming the plant and describing its spot are optional next
    /// steps the owner can take with the payoff still in view.
    private func newPlantSetupCard(for plant: Plant) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                GroveEyebrow(text: "In your grove", color: GroveTheme.accentStrong)
                GroveDisplayHeading(text: "Make \(plant.nickname) yours", style: .card)
                Text("Its first photo and baseline are saved. Add a nickname, spot and light whenever you're ready.")
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            NavigationLink(value: AppRoute.editPlant(plant.id)) {
                GroveInkLabel(title: "Personalise this plant", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(GrovePressStyle())
            .accessibilityIdentifier("finishPlantSetup")

            Button {
                IntentRouter.shared.startScan(.add)
            } label: {
                GroveOutlineLabel(title: "Scan another plant", systemImage: "camera.viewfinder")
            }
            .buttonStyle(GrovePressStyle())
            .accessibilityIdentifier("scanAnotherPlant")
        }
        .groveCard()
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                .stroke(GroveTheme.accent.opacity(0.24), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func menuContents(for plant: Plant) -> some View {
        NavigationLink(value: AppRoute.editPlant(plant.id)) {
            Label("Edit plant", systemImage: "pencil")
        }
        Button {
            plantToShare = plant
        } label: {
            Label("Share progress", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("sharePlantProgress")
        if !store.collections.isEmpty {
            Menu {
                PlantCollectionMenu(plant: plant) {
                    isCreatingCollection = true
                }
            } label: {
                Label("Add to collection", systemImage: "folder.badge.plus")
            }
            .accessibilityIdentifier("addPlantToCollection")
        }
        // The page offers one question outright; this is where the rest of them
        // live, for a person who arrived with their own.
        NavigationLink(value: AppRoute.askAbout(plant.id)) {
            Label("Ask Ari something else", systemImage: "bubble.left.and.text.bubble.right")
        }
        NavigationLink(value: AppRoute.sittingLinkForPlant(plant.id)) {
            Label("Arrange cover for \(plant.nickname)", systemImage: "person.2")
        }
        Divider()
        NavigationLink(value: AppRoute.plantHistory(plant.id)) {
            Label("Full history", systemImage: "clock.arrow.circlepath")
        }
        Divider()
        Button(role: .destructive) {
            showingRemoveConfirmation = true
        } label: {
            Label("Delete plant", systemImage: "trash")
        }
        .accessibilityIdentifier("removePlant")
    }

    private func collectionChips(_ memberships: [PlantCollection]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(memberships.prefix(4)) { collection in
                    NavigationLink(value: AppRoute.collection(collection.id)) {
                        Label(collection.name, systemImage: "square.stack.3d.up.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(GroveTheme.accentStrong)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(GroveTheme.softAccent, in: Capsule())
                    }
                    .buttonStyle(GroveTilePressStyle())
                    .groveHeroSource(.collection(collection.id))
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
    }

    // MARK: - Actions

    /// A destructive local removal happens only after the durable queue has
    /// accepted the server deletion. That ordering is what prevents the next
    /// bootstrap from resurrecting the plant after its local photos are gone.
    private func delete(_ plant: Plant) {
        let request = DeletePlantRequest(plantID: plant.id, clientRequestID: UUID())
        Task { @MainActor in
            let localOnly = syncEngine.state == .localOnly
            let accepted = await syncEngine.enqueue(
                .deletePlant(request),
                isConnected: connectivity.isConnected
            )
            guard accepted || localOnly else {
                Haptics.error()
                toasts?.show("Couldn't safely delete \(plant.nickname). Try again.", symbol: "exclamationmark.triangle.fill")
                return
            }
            withAnimation(GroveMotion.settle) { _ = store.deletePlant(id: plant.id) }
            dismiss()
        }
    }

    private func logVerifiedWatering(for plant: Plant) {
        let store = self.store
        guard let logged = store.logCare(
            plantID: plant.id,
            kind: .water,
            soilMoisture: .dry,
            force: true
        ) else {
            Haptics.error()
            return
        }
        Haptics.complete()
        recentWatering = nil
        sync(logged)
        toasts?.show(
            "Logged watering for \(plant.nickname)",
            symbol: CareKind.water.icon,
            actionTitle: "Undo"
        ) {
            undo(logged, in: store)
        }
    }

    private func log(_ kind: CareKind, for plant: Plant) {
        let store = self.store
        // "Check, then act" has to be enforced somewhere, and the moment the
        // user reaches for the watering can is the only moment it helps. The
        // store refuses a repeat watering; the page turns that refusal into the
        // question the product is built around rather than a dead tap.
        if kind == .water, let last = store.lastWatering(for: plant.id) {
            recentWatering = RecentWatering(plantID: plant.id, loggedAt: last.performedAt)
            Haptics.warning()
            return
        }
        guard let logged = store.logCare(plantID: plant.id, kind: kind) else {
            Haptics.error()
            return
        }
        Haptics.complete()
        sync(logged)
        toasts?.show(
            "Recorded \(kind.loggedTitle) for \(plant.nickname)",
            symbol: kind.icon,
            actionTitle: "Undo"
        ) {
            undo(logged, in: store)
        }
    }

    private func sync(_ task: CareTask) {
        let request = CreateCareEventRequest(task: task, clientRequestID: UUID())
        Task {
            await syncEngine.enqueue(.createCareEvent(request), isConnected: connectivity.isConnected)
        }
    }

    private func undo(_ task: CareTask, in store: GroveStore) {
        guard store.undoCompletion(taskID: task.id) != nil else { return }
        let request = DeleteCareEventRequest(taskID: task.id, clientRequestID: UUID())
        Task {
            await syncEngine.enqueue(.deleteCareEvent(request), isConnected: connectivity.isConnected)
        }
    }
}

// MARK: - Plant page blocks

/// The score, made the second thing you see rather than a small number behind
/// an info button. One dial, one band word, one direction, the age of the reading
/// — and nothing else, because provenance belongs behind the ⓘ.
private struct PlantScoreDial: View {
    let score: Int
    let band: HealthBand
    var diameter: CGFloat = 104
    var lineWidth: CGFloat = 9

    private var clamped: Int { min(max(score, 0), 100) }

    private var scale: CGFloat { diameter / 104 }
    private var showsUnit: Bool { diameter >= 72 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(GroveTheme.separator, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(clamped) / 100)
                .stroke(band.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .groveAnimation(GroveMotion.settle, value: clamped)
            VStack(spacing: -2 * scale) {
                Text("\(clamped)")
                    .font(GroveTheme.display(36 * scale))
                    .monospacedDigit()
                    .foregroundStyle(GroveTheme.ink)
                    .contentTransition(.numericText(value: Double(clamped)))
                if showsUnit {
                    Text("of 100")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GroveTheme.subtleInk)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel("Health \(clamped) out of 100, \(band.title)")
    }
}

private struct PlantScoreCard: View {
    let plant: Plant
    let takeaway: AriScanTakeaway?
    let hasCurrentEvidence: Bool

    @State private var showingEvidence = false

    private var hasScore: Bool {
        hasCurrentEvidence
            && plant.assessmentDate != nil
            && plant.confidence > 0
            && takeaway?.isProvisional != true
    }

    private var tint: Color { hasScore ? plant.healthBand.color : GroveTheme.mutedInk }

    private var provenance: String {
        var parts: [String] = []
        if let date = plant.assessmentDate {
            parts.append("Checked \(PlantPageProgress.ageLabel(date))")
        }
        if hasScore {
            parts.append("\(plant.effectiveHealthConfidence())% confidence")
        }
        return parts.isEmpty ? "No assessment saved yet" : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            // A dimmed dial reading zero is still a dial reading zero, and an
            // owner reads the number before they read the opacity. With no
            // assessment to show, the card drops the instrument rather than
            // drawing a broken one.
            if hasScore {
                PlantScoreDial(score: plant.healthScore, band: plant.healthBand)
            } else {
                GroveSymbolTile(symbol: "camera.viewfinder", tint: GroveTheme.mutedInk, size: 64)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(hasScore ? plant.healthBand.title : "Needs a fresh check-in")
                    .font(GroveTheme.display(24))
                    .foregroundStyle(hasScore ? GroveTheme.ink : GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)

                if hasScore {
                    Label(PlantConditionTrend(plant.trend).phrase, systemImage: trendSymbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                }

                Text(provenance)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { showingEvidence = true } label: {
                Image(systemName: "info.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(GroveTheme.subtleInk)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About this score")
        }
        .padding(18)
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .groveEdgeLight(radius: GroveTheme.cardRadius)
        .groveShadow(.floating)
        .accessibilityIdentifier("plantScoreCard")
        .sheet(isPresented: $showingEvidence) { evidenceSheet }
    }

    private var trendSymbol: String {
        switch plant.trend {
        case .improving: "arrow.up.right"
        case .declining: "arrow.down.right"
        case .stable, .baseline: "arrow.right"
        }
    }

    @ViewBuilder
    private var evidenceSheet: some View {
        if let takeaway {
            AriScanEvidenceView(takeaway: takeaway)
        } else {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("An estimate, based on the available record")
                            .font(.title2.bold())
                        Text("The condition score summarises the evidence recorded for this plant. It cannot measure moisture or inspect roots through a photo. A fresh check-in adds new evidence.")
                        if let date = plant.assessmentDate {
                            Text("Last assessed \(date.formatted(date: .long, time: .shortened))")
                                .font(.subheadline)
                                .foregroundStyle(GroveTheme.mutedInk)
                        }
                    }
                    .foregroundStyle(GroveTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                .groveBackground()
                .navigationTitle("Plant condition")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingEvidence = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// The words on Ari's plant-page read, kept out of the view so the rule that a
/// good scan still carries its diagnosis can be tested directly. The headline
/// is the verdict at a glance; the finding is what the scan actually saw and
/// the explanation is the qualifier that belongs with it.
struct PlantAriReadCopy: Equatable {
    let headline: String
    let finding: String
    let explanation: String?

    static func make(
        plant: Plant,
        read: PlantStateRead,
        hasCurrentEvidence: Bool,
        takeaway: AriScanTakeaway?
    ) -> PlantAriReadCopy {
        if !plant.hasHealthReading {
            return PlantAriReadCopy(
                headline: "Couldn't assess yet",
                finding: "Grove couldn't read \(plant.nickname)'s health from that photo. A clear, well-lit photo of the whole plant gives it a first reading.",
                explanation: nil
            )
        }
        guard hasCurrentEvidence else {
            return PlantAriReadCopy(
                headline: "Time for a fresh photo",
                finding: "The last photo of \(plant.nickname) is too old to say how it's doing now. A new one brings the score up to date.",
                explanation: nil
            )
        }

        let headline: String = switch read {
        case .flourishing: "Looking great"
        case .comfortable: "Looking good"
        case .dehydrated: "Needs a drink"
        case .waterlogged: "Too wet right now"
        case .stressed: "Needs attention"
        case .unassessed: "No recent photo"
        }

        // The scan's own words always beat a line keyed only to the band. A
        // healthy first scan still flagged a leaf and named a cause to check;
        // the owner came for that, not for the reassurance that nothing is due.
        let finding = takeaway?.finding.trimmingCharacters(in: .whitespacesAndNewlines)
        let explanation = takeaway?.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        if let finding, !finding.isEmpty {
            return PlantAriReadCopy(
                headline: headline,
                finding: naming(finding, nickname: plant.nickname),
                explanation: (explanation?.isEmpty == false) ? explanation.map { naming($0, nickname: plant.nickname) } : nil
            )
        }

        let fallback: String = switch read {
        case .flourishing: "Strong growth and healthy leaves in the latest photo. Keep doing what you're doing."
        case .comfortable: "Nothing needs doing today. Check the soil before you water."
        default: read.message
        }
        return PlantAriReadCopy(headline: headline, finding: fallback, explanation: nil)
    }

    /// Scans saved before the prompt learned Grove's voice open on "The plant
    /// appears…". Ari calls a plant by its name (VOICE.md), so a saved sentence
    /// that opens on the generic subject gets the name in its place.
    static func naming(_ sentence: String, nickname: String) -> String {
        guard !nickname.isEmpty else { return sentence }
        for subject in ["The plant", "This plant"] where sentence.hasPrefix(subject) {
            let rest = sentence.dropFirst(subject.count)
            guard let next = rest.first, next == " " || next == "'" || next == "’" else { continue }
            return nickname + rest
        }
        return sentence
    }
}

/// Ari says the one thing that matters, in a sentence — good or bad — and keeps
/// the reasoning one tap away. The page's old condition card opened with a
/// heading, a paragraph and two calls to action before it said anything.
///
/// The headline is the verdict at a glance; the body is what the scan actually
/// found. A healthy first scan used to collapse to "Nothing needs doing today",
/// which told the owner the band and withheld the diagnosis — the leaf it
/// flagged, the cause to check — that the analysis had already produced. A good
/// result still has content, and the diagnosis is what the owner came for.
private struct PlantAriReadCard: View {
    let plant: Plant
    let read: PlantStateRead
    let drivers: [PlantHealthDriver]
    let hasCurrentEvidence: Bool
    let takeaway: AriScanTakeaway?

    @State private var showingWhy = false

    private var copy: PlantAriReadCopy {
        PlantAriReadCopy.make(
            plant: plant,
            read: read,
            hasCurrentEvidence: hasCurrentEvidence,
            takeaway: takeaway
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image("GroveBotanist")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                Text("Diagnosis")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.mutedInk)
                Spacer(minLength: 0)
            }

            Text(copy.headline)
                .font(GroveTheme.display(26))
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text(copy.finding)
                if let explanation = copy.explanation {
                    Text(explanation)
                }
            }
            .font(.subheadline)
            .foregroundStyle(GroveTheme.mutedInk)
            .fixedSize(horizontal: false, vertical: true)

            if !drivers.isEmpty {
                DisclosureGroup(isExpanded: $showingWhy) {
                    PlantWhyList(drivers: drivers)
                        .padding(.top, 10)
                } label: {
                    Text("Why this read")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44, alignment: .leading)
                }
                .tint(GroveTheme.accentStrong)
                .accessibilityIdentifier("plantAriWhy")
            }

            if !hasCurrentEvidence {
                NavigationLink(value: AppRoute.checkIn(plant.id)) {
                    GroveInkLabel(title: "Take a fresh photo", systemImage: "camera.fill")
                }
                .buttonStyle(GrovePressStyle())
                .accessibilityIdentifier("ariFreshPhoto")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .groveAriSurface()
        .accessibilityIdentifier("plantAriRead")
    }
}

/// The ranked evidence behind Ari's read, without the card chrome it wears when
/// it stands alone.
private struct PlantWhyList: View {
    let drivers: [PlantHealthDriver]

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(drivers) { driver in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: driver.direction.symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(driver.tint)
                        .frame(width: 12)
                    Text(driver.label)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let qualifier = driver.qualifier {
                        Text(qualifier)
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(GroveTheme.subtleInk)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What Grove can honestly say about watering before anyone has felt this
/// plant's soil.
///
/// The pot is the only thing it genuinely knows on day one. The scan read the
/// material, the size, the drainage and the substrate, and that is what
/// separates "check it on Thursday" from "check it in a fortnight" for two
/// plants of the same species. The care guide's species interval cannot say it,
/// which is why that line is a range and this one is a number.
///
/// Nil once a watering or a check-in exists, because from then on the moisture
/// tile carries a dated reading and this would be a second, vaguer opinion.
struct PlantWaterRhythm: Equatable {
    let headline: String
    let reasons: [String]
    /// True when the pot itself is the problem, not the schedule.
    let isAlarming: Bool

    static func make(
        plant: Plant,
        observations: [PlantObservation],
        tasks: [CareTask],
        now: Date = .now
    ) -> PlantWaterRhythm? {
        let read = SoilMoistureRead(plant: plant, observations: observations, tasks: tasks, now: now)
        guard read.verdict == .noReading else { return nil }
        let dryDown = read.dryDown

        // A pot water cannot leave outranks any interval. Most houseplants are
        // lost this way, and a number would imply the schedule is the thing to
        // get right.
        if dryDown.holdsWater {
            return PlantWaterRhythm(
                headline: "Water can't drain out of this pot",
                reasons: read.potReasons.prefix(2).map(\.text),
                isAlarming: true
            )
        }

        let facts = read.potReasons.filter { $0.id != "pot" }.prefix(2).map(\.text)
        guard dryDown.unknownInputs <= 2 else {
            return PlantWaterRhythm(
                headline: "Feel the soil before the first water",
                reasons: facts.isEmpty ? ["Two knuckles down. Only water if it comes out dry."] : Array(facts),
                isAlarming: false
            )
        }

        let days = max(1, Int(dryDown.days.rounded()))
        return PlantWaterRhythm(
            headline: "This pot dries out in about \(days) \(days == 1 ? "day" : "days")",
            reasons: Array(facts),
            isAlarming: false
        )
    }
}

/// The errand, kept separate from the verdict above it.
///
/// `PlantPageHandoff` always knew what a plant needed next, but its only
/// consumer was a card that had been cut from the page, so the scan's own
/// instructions were collected, stored, synced and never shown. Ari's read
/// says what is true. This says what to do about it.
private struct PlantNextActionCard: View {
    let plant: Plant
    let handoff: PlantPageHandoff
    let rhythm: PlantWaterRhythm?
    /// False while the docked bar is already carrying this route. Two identical
    /// primary buttons a thumb apart is not emphasis, it is noise.
    let showsAction: Bool

    private var tint: Color {
        switch handoff.tone {
        case .urgent: GroveTheme.danger
        case .caution: GroveTheme.warning
        case .routine: GroveTheme.accentStrong
        case .calm: GroveTheme.mutedInk
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroveEyebrow(text: handoff.eyebrow, color: tint)

            Text(handoff.title)
                .font(GroveTheme.display(22))
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            if !handoff.detail.isEmpty {
                Text(handoff.detail)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let rhythm { rhythmRow(rhythm) }

            // The assessment's own instruction, when the headline above it is
            // a scheduled task rather than advice. This is the line the page
            // used to collect, store, sync and never show.
            if let recommendation = handoff.recommendation {
                Label(recommendation, systemImage: "leaf.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroveTheme.accentStrong)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("plantAssessedAction")
            }

            if showsAction, let action = handoff.action {
                NavigationLink(value: action.route) {
                    GroveInkLabel(title: action.title, systemImage: "arrow.right")
                }
                .buttonStyle(GrovePressStyle())
                .accessibilityIdentifier("plantNextAction")
            }

            if let followUp = handoff.followUp {
                Text(followUp)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.subtleInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groveCard()
        .accessibilityIdentifier("plantNextActionCard")
    }

    /// The watering answer sits inside the errand rather than in a card of its
    /// own: on the day a plant arrives, the pot's dry-down *is* the timing for
    /// the instruction directly above it.
    private func rhythmRow(_ rhythm: PlantWaterRhythm) -> some View {
        let tint = rhythm.isAlarming ? GroveTheme.warning : GroveTheme.hydration
        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: rhythm.isAlarming ? "exclamationmark.triangle.fill" : "drop.fill")
                .font(.footnote.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(rhythm.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if !rhythm.reasons.isEmpty {
                    Text(rhythm.reasons.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GroveTheme.secondarySurface,
            in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plantWaterRhythm")
    }
}

/// Whether Grove is entitled to act as though it knows what this plant is.
enum PlantIdentityState {
    /// True while the name on the page is a guess Grove cannot stand behind.
    ///
    /// Deliberately stricter than the badge on the plant record: this gates a
    /// card at the top of the page, so it fires only when the identification
    /// genuinely failed, not merely when a good photo match went unconfirmed.
    static func needsResolving(_ plant: Plant) -> Bool {
        switch plant.identityConfirmation {
        case .userConfirmed, .manualEntry:
            return false
        case .unknown:
            return true
        case .photoMatch, .none:
            // A plant with no species on it has failed identification whatever
            // the record says. Otherwise: a missing confidence is a record Grove
            // never wrote, not a match it failed. Reading `nil` as zero put this
            // card on every plant adopted before confidence was stored.
            if isUnnamed(plant) { return true }
            guard let confidence = plant.identificationConfidence else { return false }
            return confidence < 60
        }
    }

    private static func isUnnamed(_ plant: Plant) -> Bool {
        let species = plant.species.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return species.isEmpty || species == "unknown plant"
    }

    /// The stand-ins an unidentified plant is created with. They are not
    /// names: never shown as Latin, never loaded into a field as a value.
    static func isPlaceholderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty || trimmed == "species unconfirmed" || trimmed == "unknown plant"
    }
}

/// Shown only while Grove cannot name the plant, and never alongside the four
/// quieter admissions it replaces.
///
/// An unresolved identity used to surface as separate shrugs scattered down the
/// page: the care guide said "Species not confirmed yet", the light tile said
/// it held no checked requirement, the safety card said it had no reviewed
/// record. Three cards saying the same thing in three voices, and none of them
/// offering a way out. This says it once, at the top, with the two routes that
/// actually exist.
private struct PlantIdentityCard: View {
    let plant: Plant

    private var isNamed: Bool {
        let species = plant.species.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !species.isEmpty && species != "unknown plant"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroveEyebrow(text: "Species not confirmed", color: GroveTheme.warning)

            Text(isNamed ? "This might not be \(plant.species)" : "Species not identified")
                .font(GroveTheme.display(22))
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text("There's no care guide, light fit or watering schedule until the species is confirmed. Check the soil before you water. The photo diagnosis and the pet safety note still stand.")
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                NavigationLink(value: AppRoute.editPlant(plant.id)) {
                    GroveInkLabel(title: "Name it yourself", systemImage: "pencil")
                }
                .buttonStyle(GrovePressStyle())
                .accessibilityIdentifier("plantNameIdentity")

                NavigationLink(value: AppRoute.askAbout(plant.id)) {
                    GroveOutlineLabel(
                        title: "Ask Ari what it is",
                        systemImage: "bubble.left.and.text.bubble.right"
                    )
                }
                .buttonStyle(GrovePressStyle())
                .accessibilityIdentifier("plantAskIdentity")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groveCard()
        .accessibilityIdentifier("plantIdentityCard")
    }
}

/// The one fact on this page that can hurt somebody, raised to where it is read.
///
/// The full findings, their sources and the disclaimer stay in the safety card
/// further down, and this opens exactly that content rather than paraphrasing
/// it. A banner is the right rung here: persistent, contextual, and impossible
/// to dismiss by accident, without blocking the page the way a dialog would.
private struct PlantSafetyAlert: View {
    let plant: Plant
    let safety: PlantSafety

    @State private var showingDetail = false

    private var tint: Color {
        switch safety.cautionLevel {
        case .none: return GroveTheme.ink
        case .caution: return GroveTheme.warning
        case .danger: return GroveTheme.danger
        }
    }

    private var headline: String {
        switch safety.cautionLevel {
        case .danger:
            return "Harmful to \(audiences(with: .harmful))"
        case .caution:
            if safety.findings.contains(where: { $0.status == .irritant }) {
                return "Can irritate \(audiences(with: .irritant))"
            }
            return "Sources disagree about \(plant.nickname)"
        case .none:
            return ""
        }
    }

    private func audiences(with status: PlantSafety.Status) -> String {
        let names = safety.findings
            .filter { $0.status == status }
            .map(\.audience.title.localizedLowercase)
        guard !names.isEmpty else { return "pets and children" }
        return ListFormatter.localizedString(byJoining: names)
    }

    var body: some View {
        Button {
            showingDetail = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.headline)
                        .foregroundStyle(GroveTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Keep \(plant.nickname) out of reach. Tap for the sources and what to do.")
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(GroveTheme.subtleInk)
                    .accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                tint.opacity(0.10),
                in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                    .stroke(tint.opacity(0.28), lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(GroveTilePressStyle())
        .accessibilityIdentifier("plantSafetyAlert")
        .accessibilityHint("Opens the household safety findings")
        .sheet(isPresented: $showingDetail) {
            PlantSafetySheet(plant: plant, safety: safety)
        }
    }
}

/// The household safety findings as a sheet: opened by the safety alert and by
/// the plant page's "Pets and children" row, so both show the same words.
struct PlantSafetySheet: View {
    let plant: Plant
    let safety: PlantSafety

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                PlantSafetyDetail(safety: safety, plant: plant)
                    .padding(.horizontal, GroveTheme.pagePadding)
                    .padding(.vertical, 18)
            }
            .groveBackground()
            .navigationTitle("Around pets & children")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.bold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// When the next look is due, and how health has moved over time — the two
/// questions about time, answered in one card instead of two.
private struct PlantCheckInCard: View {
    let plant: Plant
    let progress: PlantPageProgress
    let seasonNote: PlantSeasonAdvisory?
    /// The scheduled look this card is counting down to.
    ///
    /// The task is the authority, because the task is what the reminder fires
    /// on. Reading `plant.nextCheckIn` alone let this card say "nothing due yet"
    /// while the docked bar and the action card, both reading the task, offered
    /// to do it now.
    let task: CareTask?

    private var dueDate: Date { task?.dueDate ?? plant.nextCheckIn }
    private var isDue: Bool { dueDate <= .now }

    /// The start of the current check-in window — the last recorded look.
    ///
    /// The ring used to be handed `nil`, which `checkInProgress` reads as "no
    /// evidence, no progress": it stood empty every day of the interval and
    /// jumped straight to full on the due date. A ring that never moves is
    /// decoration. This is the date it is actually counting from.
    private var intervalStart: Date? {
        progress.latestObservation?.createdAt ?? plant.assessmentDate
    }

    private var ringProgress: Double {
        min(1, max(0, plant.checkInProgress(since: intervalStart, at: .now)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(GroveTheme.separator, lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: isDue ? 1 : ringProgress)
                        .stroke(
                            isDue ? GroveTheme.accentStrong : GroveTheme.accent,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "camera.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isDue ? GroveTheme.accentStrong : GroveTheme.mutedInk)
                }
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    GroveEyebrow(text: "Next check-in")
                    Text(CheckInCopy.dueCaption(on: dueDate, at: .now))
                        .font(.headline)
                        .foregroundStyle(GroveTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(lastLookedLine)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 0)

                if isDue {
                    NavigationLink(value: AppRoute.checkIn(plant.id)) {
                        GroveInkLabel(title: "Check in", systemImage: "camera.fill")
                    }
                    .buttonStyle(GrovePressStyle())
                    .accessibilityIdentifier("plantCardCheckIn")
                }
            }

            PlantSectionTitle(title: "Health over time", icon: "chart.line.uptrend.xyaxis")

            if progress.readings.count >= 2 {
                HealthTrendChart(
                    series: progress.readings.map { (date: $0.date, score: $0.score) },
                    tint: plant.healthBand.color,
                    careEvents: progress.care
                )
            } else if let first = progress.readings.first {
                PlantHealthBaseline(reading: first, tint: plant.healthBand.color)
            } else {
                Text("Once you check in, \(plant.nickname)'s health over time appears here.")
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let comparison = progress.comparison {
                Divider().overlay(GroveTheme.separator)
                GroveEyebrow(text: "Then and now")
                HStack(alignment: .top, spacing: 10) {
                    previewPhoto(comparison.beforeURL, date: comparison.beforeDate, title: "Then")
                    previewPhoto(comparison.nowURL, date: comparison.nowDate, title: "Now")
                }
            }

            if let seasonNote {
                PlantSeasonBanner(advisory: seasonNote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .groveEdgeLight(radius: GroveTheme.cardRadius)
        .accessibilityIdentifier("plantCheckInCard")
    }

    private var lastLookedLine: String {
        if let latest = progress.latestObservation {
            return "Last check-in \(PlantPageProgress.ageLabel(latest.createdAt))"
        }
        // "No photo check-in yet" was true and useless on the day a plant
        // arrived: the scan that added it *is* the first look, and the page
        // was reporting it as a gap while drawing its score two cards above.
        if let assessed = plant.assessmentDate {
            return "Baseline from \(PlantPageProgress.ageLabel(assessed))"
        }
        return "No photo check-in yet"
    }

    private func previewPhoto(_ url: URL, date: Date, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ObservationThumbnail(url: url)
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
            Text(title).font(.caption.weight(.semibold))
            Text(date.formatted(.dateTime.day().month(.abbreviated)))
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The six signals as six small tiles, so the detail that used to be a wall of
/// rows is a glance. Each tile opens the existing reading sheet.
private struct PlantSignalsStrip: View {
    let plantID: UUID
    let indicators: [PlantHealthIndicator]
    /// True while the only evidence on file is the scan that added the plant.
    let isBaselineOnly: Bool
    let onLogCare: (CareKind) -> Void

    @State private var opened: PlantHealthIndicator?

    private var ordered: [PlantHealthIndicator] {
        PlantHealthIndicatorPresentation.prioritized(indicators)
    }

    /// Signals something has actually been read for, and signals nobody has
    /// closed yet. Six tiles of equal weight made a new plant's page look like
    /// a form with four fields missing; the reading is the finding, and the
    /// gaps are a footnote about what fills in next.
    private var read: [PlantHealthIndicator] { ordered.filter(\.hasReading) }
    private var unread: [PlantHealthIndicator] { ordered.filter { !$0.hasReading } }

    private var title: String {
        if !read.isEmpty && isBaselineOnly { return "What the first scan saw" }
        return read.isEmpty ? "Signals" : "What the last check-in found"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PlantSectionTitle(title: title, icon: "leaf.fill")

            if !read.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 92), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(read) { indicator in
                        tile(indicator)
                    }
                }
            }

            if !unread.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    if !read.isEmpty {
                        Divider().overlay(GroveTheme.separator)
                    }

                    Text(gapLine)
                        .font(.caption)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 132), spacing: 8)],
                        spacing: 8
                    ) {
                        ForEach(unread) { indicator in
                            gapChip(indicator)
                        }
                    }
                }
            }
        }
        .groveCard()
        .sheet(item: $opened) { indicator in
            PlantHealthIndicatorSheet(
                indicator: indicator,
                plantID: plantID,
                onLogCare: onLogCare
            )
        }
    }

    private var gapLine: String {
        let names = unread.map { shortLabel($0.kind).localizedLowercase }
        let joined = ListFormatter.localizedString(byJoining: names)
        return read.isEmpty
            ? "Nothing has been read yet. \(joined.localizedCapitalized) fill in as you check in and log care."
            : "Not read yet: \(joined). Tap one to see what closes it."
    }

    private func tile(_ indicator: PlantHealthIndicator) -> some View {
        Button {
            Haptics.tap()
            opened = indicator
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: indicator.kind.symbol)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(tint(for: indicator))
                Text(shortLabel(indicator.kind))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroveTheme.mutedInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(PlantHealthIndicatorPresentation(indicator: indicator).title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .padding(12)
            // White with a hairline, like every card in the app; the grey fill
            // was the one filled tile left on the page.
            .background(
                GroveTheme.surface,
                in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                    .strokeBorder(GroveTheme.separator, lineWidth: 1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(GroveTilePressStyle())
        .accessibilityIdentifier("plantSignal.\(indicator.kind.rawValue)")
        .accessibilityElement(children: .combine)
    }

    /// An unread signal keeps its tap target, because the sheet behind it is
    /// where the thing that closes the gap lives. It simply stops pretending
    /// to be a reading.
    private func gapChip(_ indicator: PlantHealthIndicator) -> some View {
        Button {
            Haptics.tap()
            opened = indicator
        } label: {
            HStack(spacing: 7) {
                Image(systemName: indicator.kind.symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(GroveTheme.subtleInk)
                Text(shortLabel(indicator.kind))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroveTheme.mutedInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(GroveTheme.subtleInk)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: GroveTheme.compactRadius, style: .continuous)
                    .strokeBorder(GroveTheme.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .contentShape(.rect)
        }
        .buttonStyle(GroveTilePressStyle())
        .accessibilityIdentifier("plantSignalGap.\(indicator.kind.rawValue)")
        .accessibilityLabel("\(indicator.kind.label): \(indicator.status)")
        .accessibilityElement(children: .combine)
    }

    private func shortLabel(_ kind: PlantHealthIndicatorKind) -> String {
        switch kind {
        case .moisture: "Soil"
        case .foliage: "Leaves"
        default: kind.label
        }
    }

    private func tint(for indicator: PlantHealthIndicator) -> Color {
        if PlantHealthIndicatorPresentation(indicator: indicator).priority == 0 {
            return GroveTheme.warning
        }
        if indicator.gap != nil { return GroveTheme.mutedInk }
        return GroveTheme.accentStrong
    }
}

/// The findings, their sources and the limits of all of it.
///
/// Extracted so the safety card's disclosure and the alert banner at the top of
/// the page show the same words from the same place. Two copies of a toxicity
/// answer is one copy too many.
private struct PlantSafetyDetail: View {
    let safety: PlantSafety
    let plant: Plant

    private var identityLine: String {
        if let matched = safety.matchedScientificName {
            return safety.identityIsConfirmed
                ? "Based on confirmed identity: \(matched)"
                : "Based on an unconfirmed photo match: \(matched)"
        }
        return "No exact reviewed record matched \(plant.scientificName)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(safety.findings.enumerated()), id: \.element.id) { index, finding in
                    PlantSafetyFindingRow(finding: finding)
                    if index < safety.findings.count - 1 {
                        Divider().overlay(GroveTheme.separator)
                    }
                }
            }

            Text(safety.detail)
                .font(.footnote)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            Text(identityLine)
                .font(.caption)
                .foregroundStyle(GroveTheme.subtleInk)
                .fixedSize(horizontal: false, vertical: true)

            if !safety.references.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Sources reviewed \(safety.sourcesReviewedOn)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GroveTheme.subtleInk)
                    ForEach(safety.references) { reference in
                        Link(destination: reference.url) {
                            Label("\(reference.publisher) · \(reference.title)", systemImage: "arrow.up.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(GroveTheme.accentStrong)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Open source: \(reference.publisher), \(reference.title)")
                    }
                }
            }

            Label {
                Text(PlantSafety.disclaimer)
            } icon: {
                Image(systemName: "info.circle.fill")
                    .accessibilityHidden(true)
            }
            .font(.caption2)
            .foregroundStyle(GroveTheme.subtleInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GroveTheme.separator.opacity(0.34), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Household safety, led by the answer. The full findings, sources and
/// disclaimer stay one tap down rather than filling the card.
private struct PlantPetsCard: View {
    let plant: Plant

    @State private var showingDetail = false

    private var safety: PlantSafety { PlantSafety(plant: plant) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PlantSectionTitle(title: "Around pets & children", icon: icon, tint: tint)

            Text(safety.summary)
                .font(.headline)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                ForEach([PlantSafety.Audience.cats, .dogs, .children]) { audience in
                    audienceChip(audience)
                }
            }

            if safety.matchedScientificName == nil {
                unreviewedActions
            }

            DisclosureGroup(isExpanded: $showingDetail) {
                PlantSafetyDetail(safety: safety, plant: plant)
                    .padding(.top, 6)
            } label: {
                Text("What the sources say")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44, alignment: .leading)
            }
            .tint(GroveTheme.accentStrong)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groveCard()
        .accessibilityIdentifier("plantPetsCard")
    }

    private func audienceChip(_ audience: PlantSafety.Audience) -> some View {
        let status = safety.findings.first { $0.audience == audience }?.status ?? .unverified
        let chipTint = color(for: status)
        return VStack(spacing: 6) {
            Image(systemName: audience.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(chipTint)
            Text(audience.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(GroveTheme.mutedInk)
            Text(status.title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(chipTint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 82)
        .padding(.vertical, 8)
        .background(chipTint.opacity(0.08), in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(audience.title): \(status.title)")
    }

    /// Shown only when neither the curated nor the broad catalogue has an exact
    /// record. Grove has nothing sourced to say, so the admission is set as the
    /// block's lead — not buried mid-paragraph in fine print — and the two
    /// things it can actually vouch for are the only controls: Ari, who can
    /// reason about the exact species the user names, and the ASPCA directory,
    /// which leaves the app and says so with its mark.
    private var unreviewedActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("There's no reviewed record for this exact species yet.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text("For a pet, check the ASPCA directory. If anything may have been eaten, contact a vet or poison service.")
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                NavigationLink(value: AppRoute.askAbout(plant.id)) {
                    GroveInkLabel(
                        title: "Ask Ari about this plant",
                        systemImage: "bubble.left.and.text.bubble.right"
                    )
                }
                .buttonStyle(GrovePressStyle())
                .accessibilityIdentifier("askAriUnreviewedSpecies")

                Link(destination: PlantPetsCard.aspcaDirectoryURL) {
                    GroveOutlineLabel(title: "ASPCA directory", systemImage: "arrow.up.right")
                }
                .buttonStyle(GrovePressStyle())
                .accessibilityIdentifier("openASPCADirectory")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static let aspcaDirectoryURL = URL(
        string: "https://www.aspca.org/pet-care/aspca-poison-control/toxic-and-non-toxic-plants"
    )!

    private var icon: String {
        switch safety.verdict {
        case .toxic: return "exclamationmark.triangle.fill"
        case .notKnownToBeToxic: return "checkmark.shield.fill"
        case .unverified: return "questionmark.circle.fill"
        }
    }

    private var tint: Color {
        switch safety.verdict {
        case .toxic: return GroveTheme.danger
        case .notKnownToBeToxic: return GroveTheme.accentStrong
        case .unverified: return GroveTheme.warning
        }
    }

    private func color(for status: PlantSafety.Status) -> Color {
        switch status {
        case .harmful: return GroveTheme.danger
        case .irritant, .lowRisk, .conflictingEvidence: return GroveTheme.warning
        case .noKnownToxicity: return GroveTheme.accentStrong
        case .unverified: return GroveTheme.subtleInk
        }
    }
}

/// The assessment behind Ari's note. Keep the source text and its qualifications
/// intact, and retain the corresponding photo rather than showing a newer one.
struct AriScanTakeaway: Equatable {
    let text: String
    let scanDate: Date
    let isProvisional: Bool
    let finding: String
    let explanation: String
    let photoURL: URL?
    let evidence: [String]
    let limitations: [String]
    let sourceTitle: String
    let needsFreshPhoto: Bool
    let followUpTitle: String
    let followUpDraft: String

    private struct Candidate {
        let date: Date
        let summary: String
        let isProvisional: Bool
        let photoURL: URL?
        let evidence: [String]
        let limitations: [String]
        let sourceTitle: String
        let priority: Int
    }

    static func make(
        plant: Plant,
        diagnoses: [PlantDiagnosis],
        scans: [ScanHistoryRecord],
        observations: [PlantObservation] = [],
        now: Date = .now
    ) -> AriScanTakeaway? {
        let linkedScans = scans.filter { $0.plantID == plant.id }
        var candidates: [Candidate] = diagnoses.filter { $0.plantID == plant.id }.map { diagnosis in
            Candidate(
                date: diagnosis.createdAt,
                summary: diagnosis.summary,
                isProvisional: diagnosis.actionability != nil && diagnosis.actionability != .actionable,
                photoURL: diagnosis.photoURL,
                evidence: (diagnosis.visibleConcerns ?? []) + (diagnosis.visiblePositiveSigns ?? []),
                limitations: diagnosis.limitations ?? [],
                sourceTitle: "Diagnosis",
                priority: 3
            )
        }

        if let assessedAt = plant.assessmentDate,
           let source = plant.assessmentSource,
           source == .baselinePhoto || source == .checkInPhoto || source == .diagnosisPhoto {
            // Only attach media from the matching assessment. A plant's latest
            // photo may be newer, from a different scan or an offline check-in.
            let observation = observations.first {
                $0.plantID == plant.id && !$0.isEstimated
                    && abs($0.createdAt.timeIntervalSince(assessedAt)) < 1
            }
            let scan = linkedScans.first { abs($0.createdAt.timeIntervalSince(assessedAt)) < 1 }
            candidates.append(Candidate(
                date: assessedAt,
                summary: plant.summary,
                isProvisional: plant.confidence < 50 || observation?.assessmentAvailable == false
                    || observation?.actionability == .provisional
                    || observation?.actionability == .insufficientEvidence,
                photoURL: observation?.photoURL ?? scan?.photoURL,
                evidence: plant.concerns + plant.positiveSigns,
                limitations: observation?.limitations ?? [],
                sourceTitle: source == .checkInPhoto ? "Photo check-in" : "Photo assessment",
                priority: 1
            ))
        }

        candidates += linkedScans.map { scan in
            Candidate(
                date: scan.createdAt,
                summary: scan.summary ?? "",
                isProvisional: scan.isUnknown == true,
                photoURL: scan.photoURL,
                evidence: [],
                limitations: [],
                sourceTitle: "Saved scan",
                priority: 2
            )
        }

        guard let latest = candidates.filter({ $0.date <= now }).max(by: { left, right in
            left.date == right.date ? left.priority < right.priority : left.date < right.date
        }) else { return nil }

        let original = latest.summary.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        let isStatusOnly = original.isEmpty || original.lowercased().hasPrefix("identity selected.")
        let provisional = latest.isProvisional || isStatusOnly
        let parts = sentences(in: original)
        let finding = isStatusOnly
            ? "The last scan didn't check how \(plant.nickname) is doing."
            : (parts.first ?? original)
        // Do not force a two-sentence truncation here: a later sentence may
        // qualify the finding or explain why a cause is not yet conclusive.
        let explanation = isStatusOnly
            ? "Take a fresh photo to see its condition."
            : parts.dropFirst().joined(separator: " ")
        let age = Calendar.current.dateComponents([.day], from: latest.date, to: now).day ?? 0
        let needsFreshPhoto = provisional || age >= 30 || plant.nextCheckIn <= now
        let question = provisional ? "What should I photograph?" : "What should I watch for?"
        let context = isStatusOnly ? "The saved scan has no reliable condition assessment." : original
        let draft = "About \(plant.nickname)'s \(latest.date.formatted(date: .abbreviated, time: .omitted)) scan: \(context)\n\n\(question)"

        return AriScanTakeaway(
            text: original,
            scanDate: latest.date,
            isProvisional: provisional,
            finding: finding,
            explanation: explanation,
            photoURL: latest.photoURL,
            evidence: latest.evidence,
            limitations: latest.limitations,
            sourceTitle: latest.sourceTitle,
            needsFreshPhoto: needsFreshPhoto,
            followUpTitle: question,
            followUpDraft: draft
        )
    }

    /// Exactly two compact sentences: an observation first, one action second.
    /// The scan service owns the wording for new records; the fallbacks exist
    /// for imported and pre-contract records only.
    static func twoSentence(
        condition: String,
        nextAction: String?,
        nickname: String,
        healthBand: HealthBand
    ) -> String {
        let summarySentences = sentences(in: condition)
        let conditionSentence = terminated(
            summarySentences.first
                ?? "\(nickname) looks \(healthBand.shortTitle.lowercased()) in the latest photo"
        )

        let needSentence: String
        if let action = nextAction.flatMap({ sentences(in: $0).first }) {
            needSentence = terminated("For now, \(lowercasingFirstCharacter(clause(action)))")
        } else if summarySentences.count > 1 {
            needSentence = terminated(summarySentences[1])
        } else {
            needSentence = "For now, keep its routine steady and use the next check-in to see what changed."
        }

        return "\(conditionSentence) \(needSentence)"
    }

    var sourceLabel: String {
        let date: String
        if Calendar.current.isDateInToday(scanDate) {
            date = "Today's scan"
        } else if Calendar.current.isDateInYesterday(scanDate) {
            date = "Yesterday's scan"
        } else {
            date = "Scan from \(scanDate.formatted(.dateTime.day().month(.abbreviated)))"
        }
        return date
    }

    private static func sentences(in value: String) -> [String] {
        let text = value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !text.isEmpty else { return [] }

        var result: [String] = []
        var sentence = ""
        for index in text.indices {
            let character = text[index]
            sentence.append(character)
            let nextIndex = text.index(after: index)
            let endsSentence = character == "." || character == "!" || character == "?"
            var nextWord = nextIndex
            while nextWord < text.endIndex, text[nextWord].isWhitespace {
                nextWord = text.index(after: nextWord)
            }
            // Lowercase after a full stop is normally an abbreviation (`e.g.`),
            // not the start of Ari's next sentence.
            let hasBoundary = nextWord == text.endIndex || text[nextWord].isUppercase
            if endsSentence && hasBoundary {
                let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                sentence = ""
            }
        }
        let remainder = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { result.append(remainder) }
        return result
    }

    private static func clause(_ sentence: String) -> String {
        sentence.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func terminated(_ sentence: String) -> String {
        let value = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = value.last else { return "" }
        return last == "." || last == "!" || last == "?" ? value : value + "."
    }

    private static func lowercasingFirstCharacter(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.lowercased() + value.dropFirst()
    }
}

/// Ari's finding is readable content. Evidence and conversation are separate,
/// explicitly labelled actions; opening either never sends a question.
private struct PlantAriScanTakeawayCard: View {
    let plant: Plant
    let takeaway: AriScanTakeaway
    @State private var showingScan = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var actionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image("GroveBotanist")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                Text("Diagnosis · \(takeaway.sourceLabel)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(takeaway.finding)
                .font(.title3.weight(.semibold))
                .foregroundStyle(GroveTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            if !takeaway.explanation.isEmpty {
                Text(takeaway.explanation)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if takeaway.isProvisional {
                Label("Needs a clearer assessment", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.warning)
            }

            if takeaway.needsFreshPhoto && !takeaway.isProvisional {
                Text("A fresh photo can show what has changed since this scan.")
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
            }

            actionLayout {
            Button { showingScan = true } label: {
                Label("View scan", systemImage: "photo")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(GroveTheme.accentStrong)
            .accessibilityIdentifier("ariViewScan")

            if takeaway.needsFreshPhoto && plant.effectiveLifecycleState.receivesCareReminders {
                NavigationLink(value: AppRoute.checkIn(plant.id)) {
                    Label("Take a fresh photo", systemImage: "camera")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(GroveTheme.accentStrong)
                .accessibilityIdentifier("ariFreshPhoto")
            }

            }

            NavigationLink(value: AppRoute.askAboutLatestScan(plant.id, initialDraft: takeaway.followUpDraft)) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ask Ari")
                            .font(.caption)
                            .foregroundStyle(GroveTheme.mutedInk)
                        Text(takeaway.followUpTitle)
                            .font(.subheadline.weight(.semibold))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(GroveTheme.accentStrong)
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(GrovePressStyle())
            .accessibilityHint("Opens an editable question; nothing is sent yet")
            .accessibilityIdentifier("ariScanFollowUp")
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ariScanTakeaway")
        .sheet(isPresented: $showingScan) {
            AriScanEvidenceView(takeaway: takeaway)
        }
    }
}

private struct AriScanEvidenceView: View {
    let takeaway: AriScanTakeaway
    @Environment(\.dismiss) private var dismiss
    @State private var photo: UIImage?
    @State private var photoLoaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("\(takeaway.sourceTitle) · \(takeaway.scanDate.formatted(date: .long, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)

                    if let photo {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
                            .accessibilityLabel("Original photo for this assessment")
                    } else if !photoLoaded && takeaway.photoURL != nil {
                        ProgressView("Loading scan photo")
                            .frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        Label("The original photo isn't available on this device.", systemImage: "photo")
                            .font(.subheadline)
                            .foregroundStyle(GroveTheme.mutedInk)
                    }

                    Text("The condition score is an estimate of visible condition, based on the available record. It is not a moisture reading or a measure of what is happening inside the roots.")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saved assessment").font(.headline)
                        Text(takeaway.text.isEmpty ? "No assessment was saved with this scan." : takeaway.text)
                            .font(.body)
                            .textSelection(.enabled)
                    }

                    if !takeaway.evidence.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recorded signs").font(.headline)
                            ForEach(Array(takeaway.evidence.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.subheadline)
                            }
                        }
                    }
                    if !takeaway.limitations.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What this scan couldn't confirm").font(.headline)
                            ForEach(Array(takeaway.limitations.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.subheadline)
                            }
                        }
                    }
                }
                .foregroundStyle(GroveTheme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .groveBackground()
            .navigationTitle("Scan details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: takeaway.photoURL) {
                photoLoaded = false
                photo = nil
                if let url = takeaway.photoURL, let resolved = GroveMediaPath.resolved(url) {
                    photo = await GroveThumbnailCache.thumbnail(at: resolved, maxDimension: 1400)
                }
                photoLoaded = true
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("ariScanEvidence")
    }
}

/// The two ways deeper into this plant — its record, and the voice that reads
/// it — as one card split by a hairline. They are one kind of offer, and a
/// bordered card each added a second shadow and two more full-width rules to a
/// page that is already a column of cards. The rows keep their own
/// destinations and haptics; only the chrome is shared.
private struct PlantRecordCard: View {
    let plant: Plant
    let freeAsks: Int
    let metered: Bool

    /// The meter the Ask tab has always shown, surfaced before the tap rather
    /// than after it. The row's grammar is navigation, so the fourth tap used
    /// to arrive as an error haptic and a price sheet over a sick plant without
    /// ever saying a limit existed.
    private var askDetail: String {
        guard metered else { return "Ask a question about \(plant.nickname)" }
        switch freeAsks {
        case 0: return "Today's free questions are used · opens Ask"
        case 1: return "1 free question left today"
        default: return "\(freeAsks) free questions left today"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(value: AppRoute.plantStory(plant.id)) {
                PlantRowLabel(
                    mark: .symbol("book.pages.fill"),
                    title: "See \(plant.nickname)'s story",
                    detail: "Every check-in and health score"
                )
            }
            .buttonStyle(GroveCardPressStyle())
            .accessibilityIdentifier("openPlantStory")

            PlantRowDivider()

            NavigationLink(value: AppRoute.askAbout(plant.id)) {
                PlantRowLabel(
                    mark: .artwork("GroveBotanist"),
                    title: "Ask Ari",
                    detail: askDetail
                )
            }
            .buttonStyle(GroveCardPressStyle())
            .accessibilityHint("Opens an editable question; nothing is sent yet")
            .accessibilityIdentifier("askAriAboutPlant")
        }
        .groveCard(padding: 0)
    }
}

/// Moving plant to plant without popping back to the grove list. The neighbour
/// is drawn as itself — its newest photograph, or its portrait when there is
/// none — because a row about a plant that led with a grey arrow glyph was a
/// row about an arrow.
private struct PlantNeighborCard: View {
    let previous: Plant?
    let next: Plant?

    var body: some View {
        if previous != nil || next != nil {
            VStack(spacing: 0) {
                if let previous {
                    PlantNeighborLink(plant: previous, label: "Previous plant")
                    if next != nil { PlantRowDivider() }
                }
                if let next {
                    PlantNeighborLink(plant: next, label: "Next plant")
                }
            }
            .groveCard(padding: 0)
        }
    }
}

private struct PlantNeighborLink: View {
    let plant: Plant
    let label: String

    var body: some View {
        NavigationLink(value: AppRoute.plant(plant.id)) {
            PlantRowLabel(
                mark: .portrait(plant),
                title: plant.nickname,
                detail: "\(label) · \(plant.healthBand.title)"
            )
        }
        .buttonStyle(GroveCardPressStyle())
        .accessibilityIdentifier(label == "Next plant" ? "nextPlant" : "previousPlant")
    }
}

/// One destination in the page's tail: a mark, a title, a line of detail, and
/// a chevron. The mark is what the destination *is* — a symbol for a passage
/// through the app, Grove's botanist for the conversation, the plant itself for
/// a neighbour — so four rows read as four different offers without four
/// different layouts.
private struct PlantRowLabel: View {
    enum Mark {
        case symbol(String)
        case artwork(String)
        case portrait(Plant)
    }

    let mark: Mark
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 13) {
            markView

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(GroveTheme.ink)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(GroveTheme.subtleInk)
                .accessibilityHidden(true)
        }
        .padding(PlantRowLabel.inset)
        .frame(maxWidth: .infinity, minHeight: PlantRowLabel.inset * 2 + PlantRowLabel.markSize, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var markView: some View {
        switch mark {
        case .symbol(let name):
            GroveSymbolTile(symbol: name, size: PlantRowLabel.markSize)
        case .artwork(let asset):
            GroveArtworkTile(asset: asset, size: PlantRowLabel.markSize)
        case .portrait(let plant):
            PlantThumbnail(plant: plant, height: PlantRowLabel.markSize, maxDimension: 220)
                .frame(width: PlantRowLabel.markSize, height: PlantRowLabel.markSize)
                .clipShape(Circle())
        }
    }

    static let inset: CGFloat = 14
    static let spacing: CGFloat = 13
    static let markSize: CGFloat = 44
}

/// The hairline between the rows of one card, inset to the text column so the
/// row above reads as belonging to the row below rather than to the card.
private struct PlantRowDivider: View {
    var body: some View {
        Divider()
            .overlay(GroveTheme.separator)
            .padding(.leading, PlantRowLabel.inset + PlantRowLabel.markSize + PlantRowLabel.spacing)
    }
}

/// The check-in ledger reached from the single Story button on a plant.
/// It deliberately shows observations only: the owner comes here to find every
/// check-in they completed and the score that was saved with it.
struct PlantStoryView: View {
    @Environment(GroveStore.self) private var store
    let plantID: UUID

    var body: some View {
        if let plant = store.plant(id: plantID) {
            page(for: plant)
        } else {
            GroveEmptyState(
                scene: .vanished,
                title: "Story unavailable",
                message: "This plant is no longer in your grove."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .groveBackground()
        }
    }

    private func page(for plant: Plant) -> some View {
        let checkIns = PlantStoryCheckIns.ordered(store.observations(for: plant.id))

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                GrovePageHeader(
                    title: "Check-ins",
                    subtitle: checkInSummary(count: checkIns.count)
                )

                if checkIns.isEmpty {
                    GroveEmptyState(
                        scene: .emptyShelf,
                        title: "No check-ins yet",
                        message: "Once you check in on \(plant.nickname), the date and health score will appear here."
                    )
                } else {
                    ForEach(checkIns) { checkIn in
                        PlantStoryCheckInRow(checkIn: checkIn)
                    }
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.top, GroveTheme.pageTopPadding)
            .padding(.bottom, GroveTheme.pageBottomPadding)
        }
        .groveBackground()
        .groveEditorialPage("\(plant.nickname)'s story")
        .accessibilityIdentifier("plantStoryView")
    }

    private func checkInSummary(count: Int) -> String {
        if count == 0 {
            return "Every check-in and its saved health score will live here."
        }
        return "\(count) \(count == 1 ? "check-in" : "check-ins"), newest first, with the health score saved each time."
    }
}

enum PlantStoryCheckIns {
    static func ordered(_ observations: [PlantObservation]) -> [PlantObservation] {
        observations.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.createdAt > $1.createdAt
        }
    }
}

private struct PlantStoryCheckInRow: View {
    let checkIn: PlantObservation

    private var delta: Int { checkIn.score - checkIn.previousScore }

    var body: some View {
        HStack(spacing: 15) {
            HealthScoreRing(
                score: checkIn.score,
                band: checkIn.band,
                diameter: 56,
                lineWidth: 4
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(checkIn.createdAt.formatted(.dateTime.day().month(.wide).year()))
                    .font(.headline)
                    .foregroundStyle(GroveTheme.ink)

                HStack(spacing: 7) {
                    Text(checkIn.band.shortTitle)
                        .foregroundStyle(checkIn.band.color)

                    Text("·")

                    Text(deltaText)
                        .monospacedDigit()

                    if checkIn.isEstimated {
                        Text("·")
                        Text("Estimated")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(GroveTheme.mutedInk)
            }

            Spacer(minLength: 0)
        }
        .groveCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("plantStoryCheckIn-\(checkIn.id.uuidString)")
    }

    private var deltaText: String {
        switch delta {
        case 1...: return "+\(delta) from \(checkIn.previousScore)"
        case ..<0: return "−\(abs(delta)) from \(checkIn.previousScore)"
        default: return "No change from \(checkIn.previousScore)"
        }
    }

    private var accessibilitySummary: String {
        var parts = [
            "Check-in on \(checkIn.createdAt.formatted(date: .long, time: .omitted))",
            "health score \(checkIn.score) out of 100",
            checkIn.band.title,
            deltaText
        ]
        if checkIn.isEstimated { parts.append("estimated") }
        return parts.joined(separator: ", ")
    }
}

/// Grove's primary action deepens as the next look approaches, then arrives at
/// the same fully inked CTA used for work that needs attention now.
///
/// One surface, one label. An earlier version wiped a hard-edged fill across the
/// capsule: at low progress the shard read as a misaligned layer rather than as
/// progress, and at any progress a left-to-right fill on a CTA borrows the
/// vocabulary of a loading bar — "working…" instead of "this is coming due".
private struct CheckInProgressLabel: View {
    let plant: Plant
    let startedAt: Date?
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let progress = plant.checkInProgress(since: startedAt, at: context.date)
            let isDue = progress >= 1

            HStack(spacing: 12) {
                // The due state was computed for VoiceOver and shown to nobody.
                // A pale capsule is not a sentence: a first-time owner cannot
                // read "not yet" off a background tint, and the page never said
                // when the next look was — so the largest control on the screen
                // invited the one action that was not yet useful.
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check in")
                        .font(compact ? .subheadline.weight(.bold) : .title3.weight(.bold))
                        .foregroundStyle(isDue ? GroveTheme.onCanvasButtonLabel : GroveTheme.accentStrong)
                    Text(CheckInCopy.dueCaption(on: plant.nextCheckIn, at: context.date))
                        .font(compact ? .caption.weight(.semibold) : .footnote.weight(.semibold))
                        .foregroundStyle(
                            (isDue ? GroveTheme.onCanvasButtonLabel : GroveTheme.accentStrong).opacity(0.75)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "arrow.right")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(isDue ? GroveTheme.onCanvasButton : GroveTheme.onAccent)
                    .frame(width: compact ? 36 : 46, height: compact ? 36 : 46)
                    .background {
                        Circle().fill(isDue ? GroveTheme.onCanvasButtonLabel : GroveTheme.accentStrong)
                    }
            }
            .padding(.leading, 26)
            .padding(.trailing, 8)
            .padding(.vertical, 10)
            // `minHeight`, not `frame(height:)`. The design system's own
            // contract for this height is that larger text sizes grow past it
            // via the padding (`GroveOutlineLabel` obeys it) — a fixed height
            // followed by `clipShape` meant the page's primary action clipped
            // its own label at accessibility sizes.
            .frame(minHeight: compact ? 56 : 62)
            .background {
                Capsule().fill(surface(progress: progress, isDue: isDue))
            }
            .overlay {
                // The hairline is what makes the pending state read as an outline
                // button; over the inked surface it would only muddy the edge.
                if !isDue {
                    Capsule().stroke(GroveTheme.accent.opacity(0.28), lineWidth: 1)
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .animation(.easeInOut(duration: 0.35), value: isDue)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Check in")
            .accessibilityValue(accessibilityValue(progress: progress, at: context.date))
        }
    }

    /// While pending, `softAccent` deepens toward the accent — capped well short
    /// of the accent itself so `accentStrong` type keeps clearing 4.5:1 the whole
    /// way up. Once the look is due, the surface is the inked CTA.
    private func surface(progress: Double, isDue: Bool) -> Color {
        guard !isDue else { return GroveTheme.onCanvasButton }
        return GroveTheme.softAccent.mix(with: GroveTheme.accent, by: progress * 0.3)
    }

    private func accessibilityValue(progress: Double, at date: Date) -> String {
        let days = CheckInCopy.days(until: plant.nextCheckIn, at: date)

        let dueText: String
        switch days {
        case ..<0: dueText = "Overdue"
        case 0: dueText = "Due today"
        case 1: dueText = "Due tomorrow"
        default: dueText = "Due in \(days) days"
        }

        return "\(Int((progress * 100).rounded())) percent of the check-in interval elapsed. \(dueText)."
    }
}

/// When the next look is due, in one sentence.
///
/// Shared, because the page now says it in two places — on the inline CTA and on
/// the docked bar — and two copies of a sentence are two chances for the page to
/// tell a person different things about the same plant.
enum CheckInCopy {
    static func days(until due: Date, at date: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: due)
        ).day ?? 0
    }

    static func dueCaption(on due: Date, at date: Date) -> String {
        let days = days(until: due, at: date)
        switch days {
        case ..<(-1): return "Overdue by \(abs(days)) days"
        case -1: return "Overdue by a day"
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        default: return "Next check-in in \(days) days"
        }
    }
}

// MARK: - Scroll tracking

/// Reports one edge of the view it backs, measured against the visible part of
/// the scroll view, whenever it moves. Negative means that edge has passed above
/// the top of the screen.
///
/// A preference key would do the same job, but its callback is `@Sendable` and
/// the value arrives every frame; an `onChange` inside the geometry reader is
/// both simpler and cheaper, because the caller decides what is worth a state
/// change.
private struct ScrollEdgeTracker: View {
    enum Edge { case top, bottom }

    var edge: Edge = .top
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .scrollView)
            Color.clear
                .onChange(of: edge == .top ? frame.minY : frame.maxY, initial: true) { _, value in
                    onChange(value)
                }
        }
    }
}

// MARK: - Hero

private struct PlantHero: View {
    let plant: Plant
    let recordFrames: [LivingRecordFrame]
    let height: CGFloat
    /// Room kept clear at the bottom for the vitals card that overlaps it.
    let bottomInset: CGFloat
    let onShareFilm: (GroveSharedFile) -> Void

    /// True while the Living Record is being scrubbed — the hero's editorial
    /// chrome steps aside so the record has the whole frame.
    @State private var isScrubbing = false

    @State private var isRenderingFilm = false
    @State private var filmError: String?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Only the picture stretches. Anchored to its own top and offset
            // against the overscroll, it grows downward into exactly the space
            // the rubber band opened up, while the type stays where it was.
            Group {
                if recordFrames.isEmpty {
                    // No check-in photos yet does not mean no photos: a plant
                    // added by scan already has the shot that identified it,
                    // archived against its id. Showing a gradient there put a
                    // placeholder over the best picture in the account.
                    PlantThumbnail(plant: plant, height: height, maxDimension: 1400)
                } else {
                    LivingRecordHero(plant: plant, frames: recordFrames, isScrubbing: $isScrubbing)
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            // The plant's own page is the app's second photographic window, so
            // it drifts with the device like the Today hero does. Oversized
            // first, so the drift never pulls an edge into frame; both effects
            // sit above `clipped()`, which crops whatever they do.
            .scaleEffect(1.05)
            .groveParallax(depth: 7)
            .clipped()
            .overlay { GroveAtmosphere.current.photoWash }
            .visualEffect { content, proxy in
                let stretch = max(0, proxy.frame(in: .scrollView).minY)
                return content
                    .offset(y: -stretch)
                    .scaleEffect((height + stretch) / height, anchor: .top)
            }

            // Top scrim: the back chevron and the overflow chip sit on the
            // photo, and a photo shot against a bright window would swallow
            // both of them.
            LinearGradient(
                colors: [.black.opacity(0.45), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 168)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.30), location: 0.55),
                    .init(color: .black.opacity(0.72), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 260)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .opacity(isScrubbing ? 0 : 1)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    if plant.species.caseInsensitiveCompare(plant.nickname) != .orderedSame {
                        GroveEyebrow(text: plant.species, color: .white.opacity(0.85))
                    }
                    GroveDisplayHeading(text: plant.nickname, style: .hero, color: .white)
                    Text(plant.scientificName)
                        .font(.subheadline.italic())
                        .foregroundStyle(.white.opacity(0.80))
                }
            }
            .padding(.horizontal, GroveTheme.pagePadding)
            .padding(.bottom, bottomInset + 26)
            .opacity(isScrubbing ? 0 : 1)
            .allowsHitTesting(false)

            // Sits in `PlantHero` rather than inside `LivingRecordHero` on
            // purpose: the record owns a long-press-and-drag gesture across its
            // whole frame, and a button living under that gesture is a button
            // that sometimes scrubs instead of tapping.
            if recordFrames.count >= 2 {
                filmButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 14)
                    .padding(.bottom, 58)
                    .opacity(isScrubbing ? 0 : 1)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .alert(
            "That didn't work",
            isPresented: .init(
                get: { filmError != nil },
                set: { if !$0 { filmError = nil } }
            ),
            presenting: filmError
        ) { _ in
            Button("OK", role: .cancel) { filmError = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - The record, as a file

    /// The record's way out of the app.
    ///
    /// Offered from two frames up, because a one-frame film is a photograph
    /// with extra steps — and the share sheet already handles photographs.
    private var filmButton: some View {
        Button {
            renderFilm()
        } label: {
            Group {
                if isRenderingFilm {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.38), in: Circle())
        }
        .disabled(isRenderingFilm)
        .accessibilityLabel("Share \(plant.nickname)'s record as a film")
    }

    private func renderFilm() {
        guard !isRenderingFilm else { return }
        isRenderingFilm = true
        Haptics.impact(.soft)
        Task {
            do {
                let url = try await LivingRecordFilm.render(
                    plantName: plant.nickname,
                    frames: recordFrames
                )
                onShareFilm(GroveSharedFile(url: url))
                Haptics.success()
            } catch is CancellationError {
                // The view went away mid-render. Nothing to report.
            } catch {
                filmError = "\(plant.nickname)'s record couldn't be made into a film just now. Try again in a moment."
                Haptics.error()
            }
            isRenderingFilm = false
        }
    }
}

private struct PlantPageChrome<MenuContent: View>: View {
    let title: String
    let collapsed: Bool
    let onBack: () -> Void
    @ViewBuilder var menu: () -> MenuContent

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                PlantChromeIcon(symbol: "chevron.backward", onPhoto: !collapsed)
            }
            .buttonStyle(GroveTilePressStyle())
            .accessibilityLabel("Back")

            Spacer(minLength: 8)

            GroveHeaderTitle(text: title)
                .opacity(collapsed ? 1 : 0)
                .accessibilityHidden(!collapsed)

            Spacer(minLength: 8)

            Menu {
                menu()
            } label: {
                PlantChromeIcon(symbol: "ellipsis", onPhoto: !collapsed)
            }
            .accessibilityLabel("More options for \(title)")
        }
        .padding(.horizontal, GroveTheme.pagePadding)
        .frame(height: 44)
        // Only the collapsed state gets a ground. Over the photo the hero's own
        // top scrim is what keeps the chips legible.
        .background(alignment: .top) {
            GroveTheme.background
                .opacity(collapsed ? 1 : 0)
                .ignoresSafeArea(edges: .top)
        }
    }
}

/// The overflow chip. Fixed colours in both states, because the chrome's ground
/// arrives underneath it as the hero scrolls away.
private struct PlantChromeIcon: View {
    let symbol: String
    let onPhoto: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .foregroundStyle(onPhoto ? AnyShapeStyle(Color.white) : AnyShapeStyle(GroveTheme.ink))
            .frame(width: 44, height: 44)
            .background {
                Circle().fill(onPhoto ? AnyShapeStyle(Color.black.opacity(0.35)) : AnyShapeStyle(GroveTheme.surface))
            }
            .overlay {
                Circle().stroke(
                    onPhoto ? AnyShapeStyle(Color.white.opacity(0.28)) : AnyShapeStyle(GroveTheme.separator),
                    lineWidth: 1
                )
            }
    }
}

// MARK: - Condition and the next useful action

/// The single arrow that says which way the last reading moved, in a word.
private struct PlantConditionTrend {
    let trend: HealthTrend

    init(_ trend: HealthTrend) { self.trend = trend }

    var phrase: String {
        switch trend {
        case .improving: "Trending up"
        case .declining: "Trending down"
        case .stable, .baseline: "Holding steady"
        }
    }
}

/// Only dated, assessable photo readings enter the trend. Care retains its actual date.
struct PlantPageProgress {
    struct Reading { let date: Date; let score: Int }
    let readings: [Reading]
    let comparison: PlantChangeStory.Comparison?
    let latestObservation: PlantObservation?
    let care: [CareTask]

    static func days(from: Date, to: Date) -> Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: from), to: Calendar.current.startOfDay(for: to)).day ?? 0
    }
    static func ageLabel(_ date: Date, now: Date = .now) -> String {
        let age = days(from: date, to: now)
        if age <= 0 { return "today" }
        if age == 1 { return "yesterday" }
        return "\(age) days ago"
    }
    static func make(plant: Plant, observations: [PlantObservation], scans: [ScanHistoryRecord], tasks: [CareTask], now: Date = .now) -> Self {
        let observations = observations.filter { $0.plantID == plant.id && $0.createdAt <= now }.sorted { $0.createdAt < $1.createdAt }
        var readings = observations.filter {
            !$0.isEstimated && $0.assessmentAvailable != false
                && $0.actionability != .provisional && $0.actionability != .insufficientEvidence
        }.map { Reading(date: $0.createdAt, score: $0.score) }
        if let date = plant.assessmentDate, date <= now,
           [.baselinePhoto, .checkInPhoto, .diagnosisPhoto].contains(plant.assessmentSource),
           plant.confidence >= 50,
           !observations.contains(where: { abs($0.createdAt.timeIntervalSince(date)) < 1 }),
           readings.last.map({ date > $0.date }) ?? true {
            readings.append(Reading(date: date, score: plant.healthScore))
        }
        var photos: [(Date, URL)] = observations.compactMap { observation in
            observation.photoURL.map { (observation.createdAt, $0) }
        }
        photos += scans.filter { $0.plantID == plant.id && $0.createdAt <= now }.compactMap { scan in
            scan.photoURL.map { (scan.createdAt, $0) }
        }
        photos.sort { $0.0 < $1.0 }
        let comparison: PlantChangeStory.Comparison?
        if let last = photos.last, let first = photos.first(where: { $0.0 < last.0 && $0.1 != last.1 }) {
            comparison = .init(beforeURL: first.1, beforeDate: first.0, nowURL: last.1, nowDate: last.0)
        } else { comparison = nil }
        let start = readings.dropLast().last?.date ?? observations.dropLast().last?.createdAt
        let care = tasks.filter { task in
            task.plantID == plant.id && task.isCompleted && task.kind != .checkIn && task.performedAt <= now
                && (start.map { task.performedAt >= $0 } ?? true)
        }.sorted { $0.performedAt > $1.performedAt }
        return Self(readings: readings, comparison: comparison, latestObservation: observations.last, care: Array(care.prefix(3)))
    }
}

/// A photo-led preview on the plant page, with the full chart in history.
struct PlantProgressCard: View {
    let plant: Plant
    let progress: PlantPageProgress
    var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Progress").font(.headline)
                    Spacer(minLength: 12)
                    historyLink
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Progress").font(.headline)
                    historyLink
                }
            }
            if expanded, let first = progress.readings.first, let last = progress.readings.last, progress.readings.count >= 2 {
                Text("\(last.score - first.score > 0 ? "+" : "")\(last.score - first.score) points across \(progress.readings.count) assessments")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                HealthTrendChart(series: progress.readings.map { (date: $0.date, score: $0.score) }, tint: GroveTheme.accentStrong, careEvents: progress.care)
                Text("Photo estimates · compare the photos as well as the score")
                    .font(.caption).foregroundStyle(GroveTheme.mutedInk)
            }
            if let comparison = progress.comparison {
                if expanded {
                    ObservationPhotoComparison(comparison: comparison)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        previewPhoto(comparison.beforeURL, date: comparison.beforeDate, title: "Before")
                        previewPhoto(comparison.nowURL, date: comparison.nowDate, title: "Latest")
                    }
                }
            } else if progress.latestObservation == nil {
                Label("Your starting point", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(GroveTheme.accentStrong)
                Text("Your next photo check-in will help you see what's changed.")
                    .font(.subheadline).foregroundStyle(GroveTheme.mutedInk)
            }
            if let observation = progress.latestObservation {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last check-in · \(PlantPageProgress.ageLabel(observation.createdAt))")
                        .font(.caption).foregroundStyle(GroveTheme.mutedInk)
                    Text(observation.hasNewGrowth ? "You recorded new growth" : observation.appearance.title)
                        .font(.subheadline.weight(.semibold))
                    if expanded && !observation.note.isEmpty {
                        Text(observation.note).font(.subheadline).foregroundStyle(GroveTheme.mutedInk)
                    }
                }
            }
        }
        .foregroundStyle(GroveTheme.ink)
        .padding(20)
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .accessibilityIdentifier(expanded ? "plantProgressHistory" : "plantProgressCard")
    }

    @ViewBuilder
    private var historyLink: some View {
        if !expanded {
            NavigationLink(value: AppRoute.plantHistory(plant.id)) {
                Text("View history").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
            .tint(GroveTheme.accentStrong)
        }
    }

    private func previewPhoto(_ url: URL, date: Date, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ObservationThumbnail(url: url)
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
            Text(title).font(.caption.weight(.semibold))
            Text(date.formatted(.dateTime.day().month(.abbreviated)))
                .font(.caption).foregroundStyle(GroveTheme.mutedInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Drivers

/// One piece of evidence, which way it points, and how heavily it weighs
/// against the others in the same list.
private struct PlantHealthDriver: Identifiable {
    enum Direction {
        case lifting
        case holding

        var symbol: String {
            switch self {
            case .lifting: "arrow.up"
            case .holding: "arrow.down"
            }
        }

        var tint: Color {
            switch self {
            case .lifting: GroveTheme.accent
            case .holding: GroveTheme.warning
            }
        }

        var phrase: String {
            switch self {
            case .lifting: "Lifting the read"
            case .holding: "Holding it back"
            }
        }
    }

    let id: String
    let label: String
    let direction: Direction
    /// 0…100, comparable only against the other drivers in the same list —
    /// exactly like `PlantStateRead.strength`, and for the same reason.
    let strength: Int
    /// A number Grove actually holds, where one exists. Usually nil.
    var qualifier: String?

    var tint: Color { direction.tint }

    /// The evidence behind the current read, strongest first.
    ///
    /// Sources are ordered by how directly they were observed: a diagnosis
    /// condition carries its own confidence, a check-in answer is a fact someone
    /// entered, and the summary's own bullet lists are the weakest of the three
    /// because they are prose the analysis wrote about itself.
    static func ranked(
        for plant: Plant,
        latest: PlantObservation?,
        diagnosis: PlantDiagnosis?,
        observations: [PlantObservation] = [],
        limit: Int = 5
    ) -> [PlantHealthDriver] {
        var drivers: [PlantHealthDriver] = []

        for condition in (diagnosis?.possibleConditions ?? []).prefix(2) {
            drivers.append(
                PlantHealthDriver(
                    id: "condition-\(condition.id)",
                    label: condition.name,
                    direction: .holding,
                    strength: condition.confidence,
                    qualifier: "\(condition.confidence)%"
                )
            )
        }

        if let latest {
            switch latest.soilMoisture {
            case .dry:
                drivers.append(
                    PlantHealthDriver(
                        id: "soil",
                        label: "Soil was dry at the last check-in",
                        direction: .holding,
                        strength: 75
                    )
                )
            case .wet:
                drivers.append(
                    PlantHealthDriver(
                        id: "soil",
                        label: "Soil was wet at the last check-in",
                        direction: .holding,
                        strength: 75
                    )
                )
            case .comfortable:
                drivers.append(
                    PlantHealthDriver(
                        id: "soil",
                        label: "Soil moisture looked right",
                        direction: .lifting,
                        strength: 55
                    )
                )
            }

            switch latest.appearance {
            case .worse:
                drivers.append(
                    PlantHealthDriver(
                        id: "appearance",
                        label: "Looked worse than the time before",
                        direction: .holding,
                        strength: 65
                    )
                )
            case .better:
                drivers.append(
                    PlantHealthDriver(
                        id: "appearance",
                        label: "Looked better than the time before",
                        direction: .lifting,
                        strength: 65
                    )
                )
            case .same:
                break
            }

            if latest.hasNewGrowth {
                drivers.append(
                    PlantHealthDriver(
                        id: "growth",
                        label: "New growth since the last check-in",
                        direction: .lifting,
                        strength: 70
                    )
                )
            }
        }

        // Care the owner actually logged, named as the owner's record rather
        // than as proof of cause. A recovery that happened after a move is the
        // one thing a plant owner most wants acknowledged; the page showed a
        // number that moved and never said the person moved it.
        if let recovery = PlantCareRecovery.driver(for: plant) {
            drivers.append(recovery)
        }

        // Light is the governing variable for anyone whose plant lives away
        // from a window, and no driver could ever carry it: a light problem
        // could only arrive as concern prose at strength 48, structurally below
        // wet soil. A set placement against a species guide is a real,
        // owner-reported fact and belongs in the ranking.
        if let light = PlantLightFit.driver(for: plant) {
            drivers.append(light)
        }

        // What the scan saw of the pot. A cover water cannot leave outranks
        // every piece of prose here: it is the standing reason a plant that is
        // watered correctly still rots, and until now it was computed on every
        // scan and shown on no screen.
        drivers.append(contentsOf: PlantPotConditions.drivers(for: plant))

        // The summary's own lists come last and decay by position, so a long
        // list of concerns cannot crowd out an observed fact.
        //
        // They are also gated on the same 30-day window the rest of the page
        // uses. The plant projection is timeless prose — the same sentence can
        // outlive every observation it was drawn from — so a returning owner was
        // shown "soil was dry at the last check-in" from June as what is moving
        // the read today, undated, while the card beside it had already rejected
        // that reading as too old to count.
        if PlantDetailView.hasCurrentEvidence(plant: plant, observations: observations) {
            for (index, concern) in plant.concerns.prefix(3).enumerated() {
                drivers.append(
                    PlantHealthDriver(
                        id: "concern-\(index)",
                        label: concern,
                        direction: .holding,
                        strength: 48 - index * 4
                    )
                )
            }

            for (index, sign) in plant.positiveSigns.prefix(3).enumerated() {
                drivers.append(
                    PlantHealthDriver(
                        id: "sign-\(index)",
                        label: sign,
                        direction: .lifting,
                        strength: 44 - index * 4
                    )
                )
            }
        }

        return Array(
            drivers
                .sorted { $0.strength > $1.strength }
                .prefix(limit)
        )
    }
}

/// Names the owner's own logged care as a factor in the read, without ever
/// claiming it caused the change. The store records that a recovery plan was
/// completed and what the score did between its start and its follow-up; this
/// turns that into the causal-sounding sentence the audit found no code path
/// could produce — *"You moved it to brighter light on 3 Aug"* — while keeping
/// the causation out of it.
private enum PlantCareRecovery {
    static func driver(for plant: Plant) -> PlantHealthDriver? {
        guard let plan = plant.carePlanHistory?.first,
              plan.status == .completed,
              let completedAt = plan.actions.compactMap(\.completedAt).max(),
              completedAt <= .now else { return nil }

        let instruction = plan.actions
            .first { $0.state == .completed && $0.completedAt != nil }?
            .instruction
            ?? plan.goal
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let days = PlantPageProgress.days(from: completedAt, to: .now)
        let when = days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
        return PlantHealthDriver(
            id: "care-recovery-\(plan.id.uuidString)",
            label: "You completed: \(trimmed)",
            direction: .lifting,
            strength: 68,
            qualifier: "logged \(when)"
        )
    }
}

/// A light-fit fact as a ranked driver. Only fires when both halves exist: a
/// real placement (not a guess) and a checked species guide to score it against.
private enum PlantLightFit {
    static func driver(for plant: Plant) -> PlantHealthDriver? {
        let profile = PlantCareProfile(plant: plant)
        guard profile.matchedSpecies,
              let placement = plant.effectiveLightPlacement,
              let score = profile.lightFitScore(for: placement) else { return nil }

        let isSet = plant.lightPlacement != nil
        let direction: PlantHealthDriver.Direction = score >= 80 ? .lifting : .holding
        let label = score >= 80
            ? "Light at \(placement.title.lowercased()) suits this species"
            : "Light at \(placement.title.lowercased()) is on the low side for this species"
        return PlantHealthDriver(
            id: "light",
            label: label,
            direction: direction,
            strength: 58,
            qualifier: isSet ? "\(score)% fit" : "\(score)% fit · inferred from its room"
        )
    }
}

/// Turns what the scan read off the pot into drivers of the plant's read.
///
/// These facts are the scan's most useful output and its most perishable: a
/// cachepot, standing water or gnats in the soil each change what the owner
/// should do, and none of them can be seen in a health score. They were
/// derived on every scan and rendered nowhere, because the card that drew them
/// was orphaned when the plant page was rebuilt.
///
/// Only the facts that change the advice become drivers. "20–30cm terracotta"
/// is context for the moisture tile, not a reason the plant reads the way it
/// does.
private enum PlantPotConditions {
    static func drivers(for plant: Plant) -> [PlantHealthDriver] {
        let conditions = plant.growingConditions
        let seen = conditions?.capturedAt
        return SoilMoistureRead.potReasons(for: conditions)
            .filter(\.isAlarming)
            .map { reason in
                PlantHealthDriver(
                    id: "pot-\(reason.id)",
                    label: reason.text,
                    direction: .holding,
                    strength: strength(for: reason.id),
                    qualifier: seen.map { "seen \(PlantPageProgress.ageLabel($0))" } ?? "seen in the scan"
                )
            }
    }

    /// Ranked against the observed facts around them, not against each other in
    /// isolation. A pot water cannot leave sits just above "soil was wet at the
    /// last check-in" (75), because it is the reason the soil was wet and will
    /// be wet again next week.
    private static func strength(for reasonID: String) -> Int {
        if reasonID == "drainage" { return 78 }
        if reasonID.hasPrefix("sign-") { return 72 }
        return 60
    }
}

/// Whether the calendar should temper the read or the cadence. The page had no
/// season logic at all, while `PlantLifecycleState.dormant` sat unused: a fig
/// that reads as struggling because it is January was chased every five days
/// from November to March, each honest "no new growth" answer dropping the score
/// again. This says what the month is doing, using the hemisphere the grove's
/// own latitude places it in, and leaves the decision to the owner.
struct PlantSeasonAdvisory: Equatable {
    enum Season: Equatable {
        case dormancy
        case activeGrowth
        case shoulder

        var title: String {
            switch self {
            case .dormancy: "Resting season"
            case .activeGrowth: "Growing season"
            case .shoulder: "Changing season"
            }
        }

        var detail: String {
            switch self {
            case .dormancy:
                "Most houseplants slow down now. Slower growth, and soil that stays damp longer, can be the season rather than a problem."
            case .activeGrowth:
                "This is the growing season for most houseplants. New growth and faster drying are expected."
            case .shoulder:
                "Daylight is changing, so watering and growth often shift too. Judge by the soil, not the calendar."
            }
        }

        var icon: String {
            switch self {
            case .dormancy: "moon.zzz.fill"
            case .activeGrowth: "sun.max.fill"
            case .shoulder: "leaf.fill"
            }
        }
    }

    let season: Season

    /// Nil when the grove has no location yet. A hemisphere guessed wrong flips
    /// the advice completely, so an unset location produces no note at all
    /// rather than a northern-hemisphere default.
    static func make(plant: Plant, latitude: Double?, now: Date = .now) -> PlantSeasonAdvisory? {
        guard plant.effectiveLifecycleState == .active,
              let latitude else { return nil }
        return PlantSeasonAdvisory(season: season(at: latitude, on: now))
    }

    static func season(at latitude: Double, on date: Date, calendar: Calendar = .current) -> Season {
        let month = calendar.component(.month, from: date)
        let isNorthern = latitude >= 0
        // Months are grouped rather than divided at the equinox: the meaningful
        // distinction for a houseplant is sustained light and warmth, and those
        // lag the solstice by about six weeks.
        let northern: [Int: Season] = [
            12: .dormancy, 1: .dormancy, 2: .dormancy,
            3: .shoulder, 4: .activeGrowth, 5: .activeGrowth,
            6: .activeGrowth, 7: .activeGrowth, 8: .activeGrowth,
            9: .shoulder, 10: .dormancy, 11: .dormancy
        ]
        guard let season = northern[month] else { return .shoulder }
        guard !isNorthern else { return season }
        switch season {
        case .dormancy: return .activeGrowth
        case .activeGrowth: return .dormancy
        case .shoulder: return .shoulder
        }
    }
}

private struct PlantSeasonBanner: View {
    let advisory: PlantSeasonAdvisory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: advisory.season.icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(GroveTheme.accentStrong)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(advisory.season.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(GroveTheme.ink)
                Text(advisory.season.detail)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A note inside the check-in card, separated by a hairline rather than
        // a filled green box: soft fills are gone from the rest of the app.
        .overlay(alignment: .top) {
            Rectangle().fill(GroveTheme.separator).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("plantSeasonNote")
    }
}

// MARK: - Section shell

/// The page's one section treatment: a small accent glyph, a card-scale display
/// title, and an editorial rule running out to the card's edge.
///
/// Every section used to open with a 38 pt green symbol tile, so six of them
/// marched down the page shouting equally. The rule carries the same structure
/// at a fraction of the weight.
struct PlantSection<Content: View>: View {
    let title: String
    let icon: String?
    let artwork: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        icon: String? = nil,
        artwork: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.artwork = artwork
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PlantSectionTitle(title: title, icon: icon, artwork: artwork)
            content
        }
        .groveCard()
    }
}

private struct PlantSectionTitle: View {
    let title: String
    let icon: String?
    let artwork: String?
    /// Sections colour their glyph from the accent by default. A section whose
    /// content is a warning does not: a green hazard triangle over "keep away
    /// from cats, dogs and children" is the one place on this page where the
    /// mark and the meaning disagreed.
    let tint: Color

    init(title: String, icon: String? = nil, artwork: String? = nil, tint: Color = GroveTheme.accent) {
        self.title = title
        self.icon = icon
        self.artwork = artwork
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 9) {
            if let artwork {
                Image(artwork)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
            } else if let icon {
                Image(systemName: icon)
                    .font(.footnote.weight(.black))
                    .foregroundStyle(tint)
            }
            GroveDisplayHeading(text: title, style: .card)
            Rectangle()
                .fill(GroveTheme.separator)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                // The rule takes whatever the title leaves, never the other way
                // round: without this a long title is the thing that compresses.
                .layoutPriority(-1)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Safety

private struct PlantSafetyFindingRow: View {
    let finding: PlantSafety.Finding

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: finding.audience.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.10), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(finding.audience.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink)
                    Spacer(minLength: 8)
                    Text(finding.status.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                        .multilineTextAlignment(.trailing)
                }

                Text(finding.detail)
                    .font(.caption)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch finding.status {
        case .harmful: GroveTheme.danger
        case .irritant, .lowRisk, .conflictingEvidence: GroveTheme.warning
        case .noKnownToxicity: GroveTheme.accentStrong
        case .unverified: GroveTheme.subtleInk
        }
    }
}

// MARK: - Care guide

/// The care baseline, opened in place.
///
/// This used to be a bare label floating on the canvas directly above the story
/// row, which made it read as that row's heading. As a card it says what is
/// inside and whether the species has been checked before the tap, and the
/// guide opens inside it rather than dropping onto the page underneath.
private struct PlantCareGuideDisclosure: View {
    let plant: Plant
    @State private var isExpanded = false

    private var profile: PlantCareProfile {
        PlantCareProfile(plant: plant)
    }

    private var summary: String {
        profile.matchedSpecies
            ? "Water, light, humidity and repotting"
            : "Species not confirmed yet"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            PlantCareGuide(plant: plant)
                .padding(.top, 12)
        } label: {
            HStack(spacing: 13) {
                GroveSymbolTile(symbol: "book.closed", size: 44)

                VStack(alignment: .leading, spacing: 3) {
                    GroveDisplayHeading(text: "Care guide", style: .card)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(GroveTheme.accentStrong)
        .groveCard()
        .accessibilityIdentifier("plantCareGuideDisclosure")
    }
}

/// A quick reference for the conditions this species usually prefers.
///
/// The page's live health read still owns recommendations for this particular
/// plant. These six rows are the calmer baseline underneath it: useful at a
/// glance, but deliberately phrased as checks and broad intervals rather than
/// precise calendar instructions that ignore the plant in front of you.
///
/// Drawn inside a card by its host (`PlantCareGuideSheet`), so it brings no
/// surface or section title of its own — those would be a card inside a card.
struct PlantCareGuide: View {
    let plant: Plant
    @Environment(GroveStore.self) private var store

    /// Month ranges follow the grove's hemisphere: "April–September" is the
    /// wrong half of the year in Auckland.
    private var profile: PlantCareProfile {
        PlantCareProfile(plant: plant).localized(
            southern: PlantCareProfile.isSouthernHemisphere(
                latitude: store.profile.location?.latitude,
                regionCode: store.profile.regionCode
            )
        )
    }

    private var items: [PlantCareGuideItem] {
        [
            PlantCareGuideItem(
                title: "Water",
                detail: profile.watering,
                artwork: "CareGuideWater"
            ),
            PlantCareGuideItem(
                title: "Light",
                detail: profile.light,
                artwork: "CareGuideLight"
            ),
            PlantCareGuideItem(
                title: "Humidity",
                detail: profile.humidity,
                artwork: "CareGuideHumidity"
            ),
            PlantCareGuideItem(
                title: "Fertiliser",
                detail: profile.fertilising,
                artwork: "CareGuideFertiliser"
            ),
            PlantCareGuideItem(
                title: "Repotting",
                detail: profile.repotting,
                artwork: "CareGuideRepotting"
            ),
            PlantCareGuideItem(
                title: "Temperature",
                detail: profile.temperature,
                artwork: "CareGuideTemperature"
            )
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if profile.matchedSpecies {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        careRow(item)
                        if item.id != items.last?.id {
                            Divider().overlay(GroveTheme.separator)
                        }
                    }
                }

                DisclosureGroup {
                    reviewedGuidance
                        .padding(.top, 8)
                } label: {
                    Label("About this guidance", systemImage: "checkmark.seal")
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .frame(minHeight: 44)
                }
                .tint(GroveTheme.accentStrong)
                .accessibilityIdentifier("plantCareGuidanceSources")
            } else {
                unavailableGuide
            }
        }
    }

    private var unavailableGuide: some View {
        Label {
            Text(unavailableMessage)
        } icon: {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(GroveTheme.warning)
        }
        .font(.footnote)
        .foregroundStyle(GroveTheme.mutedInk)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GroveTheme.secondarySurface,
            in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private var unavailableMessage: String {
        let species = plant.species.trimmingCharacters(in: .whitespacesAndNewlines)
        let scientific = plant.scientificName.trimmingCharacters(in: .whitespacesAndNewlines)
        if species.isEmpty || species == "Unknown plant"
            || scientific.isEmpty || scientific == "Species unconfirmed" {
            return "Confirm the species before following a care guide."
        }
        return "There's no checked care guide for \(scientific) yet."
    }

    private var reviewedGuidance: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label {
                Text(reviewedGuidanceLabel)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .accessibilityHidden(true)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(GroveTheme.subtleInk)
            .fixedSize(horizontal: false, vertical: true)

            Text("Use this as a species baseline: pot, light and season still change when this plant needs water.")
                .font(.caption2)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(profile.references) { reference in
                Link(destination: reference.url) {
                    Label("\(reference.publisher) · \(reference.title)", systemImage: "arrow.up.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(GroveTheme.accentStrong)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityLabel("Open care source: \(reference.publisher), \(reference.title)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reviewedGuidanceLabel: String {
        guard let scientificName = profile.reviewedScientificName else {
            return "Species guidance reviewed \(PlantCareProfile.sourcesReviewedOn)"
        }
        return "Reviewed for \(scientificName) · \(PlantCareProfile.sourcesReviewedOn)"
    }

    private func careRow(_ item: PlantCareGuideItem) -> some View {
        DisclosureGroup {
            Text(item.context)
                .font(.subheadline)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .padding(.bottom, 12)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(item.artwork)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GroveTheme.ink)
                    Text(item.detail)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 14)
        }
        .tint(GroveTheme.accentStrong)
        .accessibilityIdentifier("plantCareGuide.\(item.id)")
    }
}

private struct PlantCareGuideItem: Identifiable {
    let title: String
    let detail: String
    let artwork: String

    var id: String { title }

    var context: String {
        switch title {
        case "Water":
            "Use a check-in and your watering history to decide when to water. Your pot, light and season affect timing."
        case "Light":
            "The Light health indicator compares the spot recorded for this plant with its species guide. It is an estimate, not a light-meter reading."
        case "Humidity":
            "This describes the species' preference, not a measurement of the humidity around your plant."
        case "Fertiliser":
            "This is the species baseline. Check the product instructions before feeding, and record any feeding in your plant's care history."
        case "Repotting":
            "Use the plant and pot as your guide. This species advice does not mean repotting is due today."
        default:
            "This is the species' temperature guidance, not a measurement at your plant's exact spot."
        }
    }
}

// `PlantCareProfile` — the offline care baselines this screen's care guide
// reads — now lives in `PlantCareProfile.swift`, shared with the scan card.

// MARK: - Plant state

/// The single strongest thing Grove can currently say about the plant itself.
///
/// This inference used to be presented as a donut over all five states, with
/// their strengths forced to sum to 100 by largest-remainder rounding. The
/// states overlap by design — a plant can look settled overall while carrying a
/// smaller dehydration signal — so they were never parts of a whole, and the
/// card had to carry a paragraph explaining that a 0% did not mean "impossible".
/// A chart that needs a disclaimer is a second thing to decode rather than a
/// visual. What a reader actually needs from this is one sentence: which signal
/// currently leads, and what to do about it. That is all this type is now, and
/// the ranked evidence surfaces can show it as one line.
///
/// The strengths themselves are unchanged, and deliberately not percentages:
/// they are only ever compared against each other.
enum PlantStateRead: Int, CaseIterable {
    case flourishing
    case comfortable
    case dehydrated
    case waterlogged
    case stressed
    /// Nothing current enough to read from.
    ///
    /// Scores zero and so can never win the comparison — it is only ever
    /// returned explicitly, when the caller says there is no admissible
    /// evidence. Before this existed the no-evidence path fell through to
    /// `.comfortable`, so the page told a user who had been away six weeks that
    /// "the latest evidence looks settled overall" about a plant they had just
    /// decided looked ill. Reassurance is the one thing an empty hand must not
    /// produce.
    case unassessed

    /// The state best supported by the evidence Grove holds about this plant.
    ///
    /// Case order breaks ties toward the more positive, legible state, so a
    /// plant whose cues are genuinely balanced is not described by its worst
    /// one. With no signal at all — which the arithmetic below makes very
    /// unlikely, but bad synced data could still produce — the honest answer is
    /// the neutral one rather than the most flattering.
    static func strongest(
        for plant: Plant,
        latest: PlantObservation?,
        diagnosis: PlantDiagnosis?,
        hasCurrentEvidence: Bool = true
    ) -> PlantStateRead {
        guard hasCurrentEvidence else { return .unassessed }
        let scored = allCases.map {
            ($0, $0.strength(for: plant, latest: latest, diagnosis: diagnosis))
        }
        // `max(by:)` keeps the first of any equal maxima, which is what makes
        // the case order above load-bearing.
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else {
            return .unassessed
        }
        return best.0
    }

    var title: String {
        switch self {
        case .flourishing: "Flourishing"
        case .comfortable: "Comfortable"
        case .dehydrated: "Dehydrated"
        case .waterlogged: "Waterlogged"
        case .stressed: "Stressed"
        case .unassessed: "Not assessed recently"
        }
    }

    var icon: String {
        switch self {
        case .flourishing: "sparkles"
        case .comfortable: "leaf.fill"
        case .dehydrated: "drop"
        case .waterlogged: "drop.triangle.fill"
        case .stressed: "exclamationmark.triangle.fill"
        case .unassessed: "clock.badge.questionmark"
        }
    }

    var color: Color {
        switch self {
        case .flourishing: GroveTheme.healthThriving
        case .comfortable: GroveTheme.healthHealthy
        case .dehydrated: GroveTheme.gold
        case .waterlogged: GroveTheme.hydration
        case .stressed: GroveTheme.healthAttention
        case .unassessed: GroveTheme.mutedInk
        }
    }

    var message: String {
        switch self {
        case .flourishing: "Strong visible-health and growth cues lead the latest check-in."
        case .comfortable: "The latest evidence looks settled overall."
        case .dehydrated: "Dryness is the strongest current signal. Check the soil before watering."
        case .waterlogged: "Excess moisture is the strongest current signal. Let the soil guide the next step."
        case .stressed: "Visible stress is the strongest current signal. Follow the next care steps."
        case .unassessed: "This check-in is too old to use. A fresh photo updates it."
        }
    }

    /// How strongly the evidence points at this state, 0…100. Comparable
    /// between cases and meaningless on its own — nothing displays it.
    func strength(
        for plant: Plant,
        latest: PlantObservation?,
        diagnosis: PlantDiagnosis?
    ) -> Int {
        let evidence = ([plant.summary] + plant.concerns + plant.positiveSigns)
            .joined(separator: " ")
            .lowercased()

        switch self {
        case .flourishing:
            var value = max(0, (plant.healthScore - 75) * 4)
            if plant.healthBand == .thriving {
                value = max(value, plant.healthScore)
            }
            if latest?.hasNewGrowth == true {
                value = max(value, 80)
            }
            if plant.positiveSigns.contains(where: {
                Self.hasAny($0, ["new growth", "new leaf", "new leaves", "growing"])
            }) {
                value = max(value, 70)
            }
            // Positive cues can coexist with a problem, but a live attention
            // diagnosis must not leave the read calling the plant
            // "Flourishing" as its strongest current state.
            switch plant.healthBand {
            case .thriving, .healthy: break
            case .monitor: value = min(value, 30)
            case .attention: value = min(value, 15)
            case .urgent: value = 0
            }
            return Self.clamped(value)

        case .comfortable:
            // The visible-health score is the best evidence Grove has for how
            // settled the whole plant looks; specific signals below may coexist.
            var value: Int
            switch plant.healthBand {
            case .thriving, .healthy: value = plant.healthScore
            case .monitor: value = min(plant.healthScore, 45)
            case .attention: value = min(plant.healthScore, 20)
            case .urgent: value = 0
            }
            // A moisture reading the owner entered outranks an inference drawn
            // from the score. Without this cap the whole healthy band (75–89)
            // beat `.waterlogged`'s flat 75, so the page told someone whose
            // soil was wet that things "look settled overall" and only admitted
            // the problem once overwatering had already dragged the score under
            // 75 — withholding the warning until it was too late to be useful.
            if latest?.soilMoisture == .wet || latest?.soilMoisture == .dry {
                value = min(value, 60)
            }
            return Self.clamped(value)

        case .dehydrated:
            var value = Self.conditionConfidence(
                in: diagnosis,
                matching: [
                    "dehydrat", "underwater", "drought", "moisture deficit", "too dry", "dry soil"
                ]
            )
            if latest?.soilMoisture == .dry {
                value = max(value, 75)
            }
            if Self.hasAny(evidence, ["dehydrat", "underwater", "moisture deficit", "too dry", "dry soil"]) {
                value = max(value, 40)
            }
            return Self.clamped(value)

        case .waterlogged:
            var value = Self.conditionConfidence(
                in: diagnosis,
                matching: [
                    "overwater", "excess moisture", "waterlog", "root rot", "soggy", "too wet", "wet soil"
                ]
            )
            if latest?.soilMoisture == .wet {
                value = max(value, 75)
            }
            if Self.hasAny(evidence, ["overwater", "excess moisture", "waterlog", "soggy", "too wet", "wet soil"]) {
                value = max(value, 40)
            }
            return Self.clamped(value)

        case .stressed:
            var value = 100 - plant.healthScore
            switch plant.healthBand {
            case .thriving, .healthy:
                break
            case .monitor:
                value = max(value, 55)
            case .attention:
                value = max(value, 75)
            case .urgent:
                value = max(value, 100)
            }
            if latest?.appearance == .worse {
                value = max(value, 50)
            }
            if !plant.concerns.isEmpty {
                value = max(value, 25)
            }
            return Self.clamped(value)

        case .unassessed:
            // Never competes. `strongest` returns it explicitly or not at all.
            return 0
        }
    }

    private static func conditionConfidence(
        in diagnosis: PlantDiagnosis?,
        matching terms: [String]
    ) -> Int {
        diagnosis?.possibleConditions
            .filter {
                let evidence = ([$0.name, $0.explanation] + $0.evidence)
                    .joined(separator: " ")
                    .lowercased()
                return hasAny(evidence, terms)
            }
            .map(\.confidence)
            .max() ?? 0
    }

    private static func hasAny(_ text: String, _ terms: [String]) -> Bool {
        let normalized = text.lowercased()
        return terms.contains { normalized.contains($0) }
    }

    private static func clamped(_ value: Int) -> Int {
        min(100, max(0, value))
    }
}

/// The six signals Grove can calculate without claiming to have a sensor in
/// the room: soil moisture, light fit, what the leaves look like, posture,
/// growth and the owner's care rhythm. A score is only present when the input
/// exists; a missing one carries a `gap` saying why and, where the owner can do
/// something about it, the one action that closes it.
struct PlantHealthIndicator: Identifiable, Hashable {
    typealias Kind = PlantHealthIndicatorKind

    /// The single thing the owner can do to turn a blank tile into a reading.
    /// Nothing else belongs here: a tile that offers two ways forward is a tile
    /// nobody acts on.
    enum Remedy: Hashable {
        /// A photograph is the only input for the things you can see, and
        /// for the soil too since the hand-in-the-soil ritual was retired.
        case checkIn
        /// A few logged waterings are what a rhythm is made of.
        case logCare
        /// Nobody has said where the plant stands relative to a window.
        case setLight

        var title: String {
            switch self {
            case .checkIn: "Check in"
            case .logCare: "Log care"
            case .setLight: "Set the spot"
            }
        }

        var symbol: String {
            switch self {
            case .checkIn: "camera.fill"
            case .logCare: "checkmark.circle.fill"
            case .setLight: "sun.max.fill"
            }
        }
    }

    /// Why there is no number, in words the owner can act on.
    ///
    /// This exists because "No read" was one label over three unrelated
    /// situations: nobody has ever looked, the last look has aged out, and the
    /// last look simply did not mention this area. The first two are the
    /// owner's to fix and the third is not, and a tile that cannot tell them
    /// apart is asking the owner to guess which one they are in.
    struct Gap: Hashable {
        let reason: String
        let remedy: Remedy?
    }

    let kind: Kind
    let score: Int?
    let status: String
    let detail: String
    /// Present only when Grove lacks a reading. A categorical observation can
    /// legitimately have no score and no gap.
    var gap: Gap? = nil
    var evidenceLevel: PlantHealthIndicatorEvidenceLevel? = nil
    var source: PlantHealthIndicatorSource? = nil
    var confidence: Int? = nil
    var recordedAt: Date? = nil
    var algorithmVersion: String? = nil
    /// What the scan read off the pot, for the tiles where the pot is part of
    /// the answer. Only moisture fills this today, and it is the one place the
    /// owner can see the drainage and surface facts in full: the page's "Why
    /// this read" list carries only the alarming ones, and only as many as fit.
    var potFacts: [SoilMoistureRead.Reason] = []

    var id: Kind { kind }
    var hasReading: Bool { gap == nil }
}

extension PlantHealthIndicatorKind {
    var label: String {
        switch self {
        case .moisture: "Moisture"
        case .light: "Light"
        case .foliage: "Foliage"
        case .posture: "Posture"
        case .growth: "Growth"
        case .care: "Care rhythm"
        }
    }

    var symbol: String {
        switch self {
        case .moisture: "drop.fill"
        case .light: "sun.max.fill"
        case .foliage: "leaf.fill"
        case .posture: "arrow.up.to.line"
        case .growth: "chart.line.uptrend.xyaxis"
        case .care: "calendar.badge.clock"
        }
    }

    var subject: String {
        switch self {
        case .moisture: "the soil"
        case .light: "light"
        case .foliage: "leaf colour and damage"
        case .posture: "how it is holding itself"
        case .growth: "new growth"
        case .care: "your care rhythm"
        }
    }

    var readsFrom: String {
        switch self {
        case .moisture: "Check-in observations, recorded waterings and the plant's scan."
        case .light: "The spot you set, against the light this species wants."
        case .foliage: "Structured leaf-colour and damage findings from the latest photo."
        case .posture: "A structured posture finding from the latest photo."
        case .growth: "New growth observed by you or found in the latest photo."
        case .care: "The waterings you have recorded."
        }
    }
}

/// Pure, small calculations for the six-tile health read. Keeping this
/// separate from the tile layout means the numbers can be tested without a
/// view renderer and makes the evidence rules visible in one place.
enum PlantHealthIndicators {
    private static let stateWindowDays = 30
    static let algorithmVersion = "health-indicators.2026-08-30.v1"

    /// Whether anything Grove has been shown still speaks for the plant as it
    /// looks now, and when it does not, how the tile should say so.
    enum PhotoEvidence: Hashable {
        /// A check-in, diagnosis, or baseline carrying actual assessment
        /// evidence inside the state window.
        case current
        /// There have been check-ins, and the newest is older than the window.
        case aged(days: Int)
        /// Grove has never been shown this plant since it was added.
        case never
    }

    static func make(
        for plant: Plant,
        observations: [PlantObservation],
        diagnosis: PlantDiagnosis?,
        tasks: [CareTask],
        location: GroveLocation? = nil,
        now: Date = .now
    ) -> [PlantHealthIndicator] {
        let cutoff = Calendar.current.date(
            byAdding: .day,
            value: -stateWindowDays,
            to: now
        ) ?? .distantPast
        let newest = observations
            .filter { $0.createdAt <= now }
            .max { $0.createdAt < $1.createdAt }
        let latest = (newest?.createdAt ?? .distantPast) >= cutoff ? newest : nil
        let photo: PhotoEvidence
        let diagnosisIsCurrent = diagnosis.map { $0.createdAt >= cutoff && $0.createdAt <= now } ?? false
        let baselineIsCurrent = plant.assessmentDate.map { $0 >= cutoff && $0 <= now } ?? false
        if diagnosisIsCurrent || latest != nil || baselineIsCurrent {
            photo = .current
        } else if let newest {
            photo = .aged(days: Self.wholeDays(from: newest.createdAt, to: now))
        } else {
            photo = .never
        }

        let durable = Self.currentReadings(
            plant: plant,
            observation: latest,
            diagnosis: diagnosisIsCurrent ? diagnosis : nil,
            now: now
        )
        // Older confirmation code erased condition availability even when the
        // owner accepted the original match. Its retained visible signs still
        // describe that photo; recover those specific legacy records too.
        let legacyConfirmationReset = plant.identityConfirmation == .userConfirmed
            && plant.summary.hasPrefix("Identity selected. Use a fresh photo to establish condition-specific care")
        let recoveredVisual = baselineIsCurrent && (plant.confidence >= 50 || legacyConfirmationReset)
            ? Self.fallbackVisualFindings(
                positiveEvidence: plant.positiveSigns,
                concernEvidence: plant.concerns,
                confidence: plant.confidence
            )
            : [:]
        let baselineDate = plant.assessmentDate ?? now

        func visualReading(for kind: PlantHealthIndicatorKind) -> PlantHealthIndicatorReading? {
            if let reading = durable[kind], reading.evidenceLevel != .unavailable {
                return reading
            }
            // A later assessment saying it cannot see a signal supersedes the
            // baseline. Do not silently restore an older positive observation.
            if let reading = durable[kind], reading.measuredAt.timeIntervalSince(baselineDate) > 1 {
                return reading
            }
            if let finding = recoveredVisual[kind] {
                return Self.visualReading(
                    from: finding,
                    at: baselineDate,
                    version: Self.algorithmVersion
                )
            }
            return durable[kind]
        }

        return [
            Self.moisture(
                plant: plant,
                observation: latest,
                tasks: tasks,
                durableReading: durable[.moisture],
                location: location,
                now: now
            ),
            Self.light(plant: plant),
            Self.visual(kind: .foliage, reading: visualReading(for: .foliage), photo: photo),
            Self.visual(kind: .posture, reading: visualReading(for: .posture), photo: photo),
            Self.visual(kind: .growth, reading: visualReading(for: .growth), photo: photo),
            Self.care(plant: plant, tasks: tasks, location: location, now: now)
        ]
    }

    /// The complete six-reading snapshot stored with every new assessment.
    /// Direct owner observations stay useful even if photo analysis is
    /// unavailable; visual signals explicitly record that they were unavailable.
    static func recordedReadings(
        for plant: Plant,
        soil: ObservationSoilMoisture?,
        hasNewGrowth: Bool?,
        visualFindings: [PlantVisualIndicatorFinding],
        growingConditions: PlantGrowingConditions? = nil,
        tasks: [CareTask],
        assessmentAvailable: Bool,
        analysisVersion: String?,
        now: Date = .now
    ) -> [PlantHealthIndicatorReading] {
        let version = analysisVersion ?? algorithmVersion
        let visualByKind = Dictionary(
            visualFindings.map { ($0.kind, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let moistureReading: PlantHealthIndicatorReading
        if let soil {
            let status: String
            let detail: String
            switch soil {
            case .dry:
                status = "Dry"
                detail = "You felt dry soil at this check-in."
            case .comfortable:
                status = "Damp"
                detail = "You felt damp soil at this check-in."
            case .wet:
                status = "Wet"
                detail = "You felt wet soil at this check-in."
            }
            moistureReading = PlantHealthIndicatorReading(
                kind: .moisture,
                value: soil.rawValue,
                score: nil,
                status: status,
                detail: detail,
                evidenceLevel: .observed,
                source: .ownerReport,
                confidence: nil,
                evidence: ["Soil felt a few centimetres below the surface"],
                measuredAt: now,
                validUntil: Calendar.current.date(byAdding: .day, value: 1, to: now),
                algorithmVersion: version
            )
        } else if assessmentAvailable,
                  let surfaceReading = surfaceMoistureReading(
                    from: growingConditions,
                    at: now,
                    version: version
                  ) {
            moistureReading = surfaceReading
        } else {
            moistureReading = unavailableReading(
                kind: .moisture,
                status: "No reading yet",
                detail: "No soil observation was supplied with this assessment.",
                at: now,
                version: version
            )
        }

        let lightReading = durable(
            from: light(plant: plant),
            value: plant.effectiveLightPlacement?.rawValue ?? "unavailable",
            at: now,
            version: version
        )

        let visualKinds: [PlantHealthIndicatorKind] = [.foliage, .posture]
        let visualReadings = visualKinds.map { kind -> PlantHealthIndicatorReading in
            guard assessmentAvailable, let finding = visualByKind[kind], finding.state != .unavailable else {
                return unavailableReading(
                    kind: kind,
                    status: "Not visible",
                    detail: assessmentAvailable
                        ? "This scan couldn't clearly assess \(kind.subject). Take a closer photo at your next check-in."
                        : "The photo did not support a reliable condition assessment.",
                    at: now,
                    version: version
                )
            }
            return visualReading(from: finding, at: now, version: version)
        }

        let growthReading: PlantHealthIndicatorReading
        if let hasNewGrowth {
            growthReading = PlantHealthIndicatorReading(
                kind: .growth,
                value: hasNewGrowth ? "new-growth" : "none-spotted",
                score: nil,
                status: hasNewGrowth ? "Active" : "None spotted",
                detail: hasNewGrowth
                    ? "You recorded new growth at this check-in."
                    : "You did not spot new growth at this check-in. This is an observation, not a poor-health score.",
                evidenceLevel: .observed,
                source: .ownerReport,
                confidence: nil,
                evidence: [hasNewGrowth ? "Owner reported new growth" : "Owner reported no new growth"],
                measuredAt: now,
                validUntil: Calendar.current.date(byAdding: .day, value: stateWindowDays, to: now),
                algorithmVersion: version
            )
        } else if assessmentAvailable, let finding = visualByKind[.growth], finding.state != .unavailable {
            growthReading = visualReading(from: finding, at: now, version: version)
        } else {
            growthReading = unavailableReading(
                kind: .growth,
                status: "Not visible",
                detail: "This scan couldn't clearly show new growth. You can record any new leaves or shoots at your next check-in.",
                at: now,
                version: version
            )
        }

        let careReading = durable(
            from: care(plant: plant, tasks: tasks, now: now),
            value: "care-history",
            at: now,
            version: version
        )
        return [moistureReading, lightReading] + visualReadings + [growthReading, careReading]
    }

    private static func currentReadings(
        plant: Plant,
        observation: PlantObservation?,
        diagnosis: PlantDiagnosis?,
        now: Date
    ) -> [PlantHealthIndicatorKind: PlantHealthIndicatorReading] {
        let candidates = (observation?.indicatorReadings ?? [])
            + (diagnosis?.indicatorReadings ?? [])
            + (plant.healthIndicatorReadings ?? [])
        var result: [PlantHealthIndicatorKind: PlantHealthIndicatorReading] = [:]
        for reading in candidates {
            guard reading.measuredAt <= now,
                  reading.validUntil.map({ $0 >= now }) ?? true else { continue }
            if result[reading.kind].map({ $0.measuredAt >= reading.measuredAt }) == true { continue }
            result[reading.kind] = reading
        }
        return result
    }

    private static func moisture(
        plant: Plant,
        observation: PlantObservation?,
        tasks: [CareTask],
        durableReading: PlantHealthIndicatorReading?,
        location: GroveLocation?,
        now: Date
    ) -> PlantHealthIndicator {
        let read = SoilMoistureRead(
            plant: plant,
            observations: observation.map { [$0] } ?? [],
            tasks: tasks,
            location: location,
            now: now
        )
        // The pot explains the reading in every branch below, including the
        // ones with no reading at all — "pot never scanned" is itself why the
        // tile is empty.
        var indicator = moistureVerdict(
            plant: plant,
            read: read,
            durableReading: durableReading,
            now: now
        )
        indicator.potFacts = read.potReasons
        return indicator
    }

    private static func moistureVerdict(
        plant: Plant,
        read: SoilMoistureRead,
        durableReading: PlantHealthIndicatorReading?,
        now: Date
    ) -> PlantHealthIndicator {
        switch read.verdict {
        case .ready:
            return PlantHealthIndicator(
                kind: .moisture,
                score: nil,
                status: "Dry",
                detail: "The moisture estimate has reached the dry end. Check the soil before watering.",
                evidenceLevel: .estimated,
                source: .careHistory,
                recordedAt: read.evidence?.recordedAt,
                algorithmVersion: algorithmVersion
            )
        case .holding:
            let isHigh = read.position > 0.82
            let isFreshObservation = read.evidence.map {
                $0.source != .watering && now.timeIntervalSince($0.recordedAt) <= SoilMoistureRead.freshFeelWindow
            } ?? false
            return PlantHealthIndicator(
                kind: .moisture,
                score: nil,
                status: isHigh ? "Wet" : "Damp",
                detail: isHigh
                    ? "The soil is still holding a lot of moisture."
                    : "The current moisture reading is in a comfortable range.",
                evidenceLevel: isFreshObservation ? .observed : .estimated,
                source: isFreshObservation ? .ownerReport : .careHistory,
                recordedAt: read.evidence?.recordedAt,
                algorithmVersion: algorithmVersion
            )
        case .unclear:
            return Self.noRead(
                .moisture,
                status: "Too close to call",
                reason: "The estimate straddles the watering line. A fresh check-in will sharpen it.",
                remedy: .checkIn
            )
        case .noReading:
            if let durableReading, durableReading.evidenceLevel != .unavailable {
                return display(durableReading)
            }
            let capturedAt = plant.growingConditions?.capturedAt ?? plant.assessmentDate
            if let capturedAt,
               let surfaceReading = surfaceMoistureReading(
                    from: plant.growingConditions,
                    at: capturedAt,
                    version: algorithmVersion
               ),
               surfaceReading.measuredAt <= now,
               surfaceReading.validUntil.map({ $0 >= now }) ?? true {
                return display(surfaceReading)
            }
            return Self.noRead(
                .moisture,
                status: "No reading yet",
                reason: "This comes from a check-in, a recorded watering or the scan. There's nothing to go on yet.",
                remedy: .checkIn
            )
        }
    }

    /// Resolves the photo-only findings from a scan response.
    ///
    /// Current gateways return one typed item for each visual signal. Builds
    /// can, however, receive a completed job created by the previous gateway
    /// contract, which only carried `positiveSigns` and `concerns`. Those
    /// arrays are still explicitly photo-grounded evidence, so use a narrow
    /// vocabulary to recover only the signal each sentence actually names.
    /// An overall score or summary is never used to fill a tile.
    static func visualFindings(from condition: PlantConditionResult) -> [PlantVisualIndicatorFinding] {
        let structured = condition.indicatorFindings ?? []
        var byKind = Dictionary(
            structured.map { ($0.kind, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let fallback = fallbackVisualFindings(
            positiveEvidence: condition.positiveSigns,
            concernEvidence: condition.concerns,
            confidence: condition.confidence
        )

        for kind in [PlantHealthIndicatorKind.foliage, .posture, .growth] {
            if let current = byKind[kind], current.state != .unavailable { continue }
            if let recovered = fallback[kind] { byKind[kind] = recovered }
        }

        return [PlantHealthIndicatorKind.foliage, .posture, .growth]
            .compactMap { byKind[$0] }
    }

    private static func fallbackVisualFindings(
        positiveEvidence: [String],
        concernEvidence: [String],
        confidence: Int
    ) -> [PlantHealthIndicatorKind: PlantVisualIndicatorFinding] {
        var findings: [PlantHealthIndicatorKind: PlantVisualIndicatorFinding] = [:]
        let boundedConfidence = min(100, max(0, confidence))
        for kind in [PlantHealthIndicatorKind.foliage, .posture, .growth] {
            let concerns = concernEvidence.filter { evidence($0, names: kind) }
            let positives = positiveEvidence.filter { evidence($0, names: kind) }
            if !concerns.isEmpty {
                findings[kind] = PlantVisualIndicatorFinding(
                    kind: kind,
                    state: .watch,
                    severity: 1,
                    confidence: boundedConfidence,
                    evidence: Array(concerns.prefix(5))
                )
            } else if !positives.isEmpty {
                findings[kind] = PlantVisualIndicatorFinding(
                    kind: kind,
                    state: .good,
                    severity: 0,
                    confidence: boundedConfidence,
                    evidence: Array(positives.prefix(5))
                )
            }
        }
        return findings
    }

    private static func evidence(_ line: String, names kind: PlantHealthIndicatorKind) -> Bool {
        let text = line.lowercased()
        let terms: [String]
        switch kind {
        case .foliage:
            terms = [
                "leaf", "leaves", "foliage", "frond", "needle", "colour", "color",
                "yellow", "brown", "spot", "margin", "lesion", "chloros", "discolo"
            ]
        case .posture:
            terms = [
                "posture", "stem", "upright", "droop", "wilt", "firm", "collapse",
                "lean", "curl", "turgor", "cane", "branch"
            ]
        case .growth:
            terms = [
                "new growth", "new leaf", "new leaves", "new shoot", "new shoots",
                "bud", "emerging", "emergence"
            ]
        case .moisture, .light, .care:
            return false
        }
        return terms.contains { text.contains($0) }
    }

    private static func surfaceMoistureReading(
        from conditions: PlantGrowingConditions?,
        at date: Date,
        version: String
    ) -> PlantHealthIndicatorReading? {
        guard let conditions,
              conditions.confidence > 0,
              [
                PlantGrowingConditions.SoilSurface.dry,
                .damp,
                .wet
              ].contains(conditions.soilSurface) else { return nil }
        let status: String
        switch conditions.soilSurface {
        case .dry: status = "Surface dry"
        case .damp: status = "Surface damp"
        case .wet: status = "Surface wet"
        case .obscured, .unknown: return nil
        }
        return PlantHealthIndicatorReading(
            kind: .moisture,
            value: "surface-\(conditions.soilSurface.rawValue)",
            score: nil,
            status: status,
            detail: "The scan could only see the soil surface. Feel a few centimetres down before deciding whether to water.",
            evidenceLevel: .observed,
            source: .photoAnalysis,
            confidence: min(100, max(0, conditions.confidence)),
            evidence: ["Soil surface appeared \(conditions.soilSurface.rawValue) in the scan"],
            measuredAt: date,
            validUntil: Calendar.current.date(byAdding: .day, value: 1, to: date),
            algorithmVersion: version
        )
    }

    private static func light(plant: Plant) -> PlantHealthIndicator {
        let profile = PlantCareProfile(plant: plant)
        guard profile.matchedSpecies else {
            return Self.noRead(
                .light,
                status: "Guide not checked",
                reason: "There's no checked light requirement for this species yet, so the spot isn't scored.",
                remedy: nil
            )
        }
        guard let placement = plant.effectiveLightPlacement else {
            return Self.noRead(
                .light,
                status: "Spot not set",
                reason: "Nobody has said where this plant stands relative to a window, so there is nothing to score its light against.",
                remedy: .setLight
            )
        }

        guard let score = profile.lightFitScore(for: placement) else {
            return Self.noRead(
                .light,
                status: "Guide not checked",
                reason: "There's no checked light requirement for this species yet, so the spot isn't scored.",
                remedy: nil
            )
        }
        let status = score >= 80 ? "Good" : score >= 60 ? "Fair" : "Low"
        let source = plant.lightPlacement == nil ? "Inferred from its location" : placement.title
        return PlantHealthIndicator(
            kind: .light,
            score: score,
            status: "\(status) fit",
            detail: "\(source). This is a placement-to-species estimate; the app did not measure light at the plant.",
            evidenceLevel: .estimated,
            source: .speciesGuide,
            algorithmVersion: algorithmVersion
        )
    }

    private static func visual(
        kind: PlantHealthIndicator.Kind,
        reading: PlantHealthIndicatorReading?,
        photo: PhotoEvidence
    ) -> PlantHealthIndicator {
        guard let reading else { return Self.photoGap(kind, photo: photo) }
        return display(reading)
    }

    private static func care(
        plant: Plant,
        tasks: [CareTask],
        location: GroveLocation? = nil,
        now: Date
    ) -> PlantHealthIndicator {
        let completedCare = tasks.filter {
            $0.plantID == plant.id && $0.isCompleted && $0.kind != .checkIn
        }
        let rhythm = WateringRhythm(plantID: plant.id, tasks: tasks, now: now)

        guard rhythm.isReadable, let typicalDays = rhythm.typicalDays else {
            if completedCare.isEmpty {
                return Self.noRead(
                    .care,
                    status: "No care recorded",
                    reason: "Your care history builds over time. After a few check-ins and waterings, this fills in.",
                    remedy: .logCare
                )
            }
            return PlantHealthIndicator(
                kind: .care,
                score: 55,
                status: "Building",
                detail: "A few more care logs will make this rhythm more useful.",
                evidenceLevel: .estimated,
                source: .careHistory,
                algorithmVersion: algorithmVersion
            )
        }

        let typical = Double(typicalDays)
        let deviations = rhythm.intervals.map { abs(Double($0.days) - typical) }
        let consistency = 1 - min(1, (Self.median(deviations) ?? 0) / max(2, typical * 0.6))
        let target = max(3, SoilDryDown(plant: plant, location: location, now: now).days)
        let cadenceFit = 1 - min(1, abs(typical - target) / max(3, target))
        var score = 55 + cadenceFit * 25 + consistency * 20
        if let daysSinceLast = rhythm.daysSinceLast, Double(daysSinceLast) > target * 1.5 {
            score -= 18
        }
        let clamped = min(96, max(30, Int(score.rounded())))
        let status = clamped >= 80 ? "On track" : clamped >= 60 ? "Uneven" : "Needs care"
        return PlantHealthIndicator(
            kind: .care,
            score: clamped,
            status: status,
            detail: "A \(typicalDays)-day median across \(rhythm.waterings.count) recorded waterings. This measures recorded care, not the plant's biology.",
            evidenceLevel: .estimated,
            source: .careHistory,
            algorithmVersion: algorithmVersion
        )
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func wholeDays(from start: Date, to end: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: start),
            to: calendar.startOfDay(for: end)
        ).day ?? 0
    }

    /// The three signals that can only be read off a photograph, when there is
    /// no usable photograph. Named separately from `unremarked` because these
    /// are the owner's to fix and that one is not.
    private static func photoGap(
        _ kind: PlantHealthIndicator.Kind,
        photo: PhotoEvidence
    ) -> PlantHealthIndicator {
        switch photo {
        case .current:
            // Callers guard on this; falling through to the never state is the
            // safe answer rather than inventing a score.
            return Self.noRead(
                kind,
                status: "No check-in yet",
                reason: "\(kind.subject.prefix(1).uppercased() + kind.subject.dropFirst()) comes from your check-in photos.",
                remedy: .checkIn
            )
        case .aged(let days):
            return Self.noRead(
                kind,
                status: "Needs a fresh check-in",
                reason: "The last check-in was \(days) \(days == 1 ? "day" : "days") ago. Too old to say anything about \(kind.subject) today.",
                remedy: .checkIn
            )
        case .never:
            return Self.noRead(
                kind,
                status: "No check-in yet",
                reason: "\(kind.subject.prefix(1).uppercased() + kind.subject.dropFirst()) comes from your check-in photos, and there hasn't been one since you added this plant.",
                remedy: .checkIn
            )
        }
    }

    private static func noRead(
        _ kind: PlantHealthIndicator.Kind,
        status: String,
        reason: String,
        remedy: PlantHealthIndicator.Remedy?
    ) -> PlantHealthIndicator {
        PlantHealthIndicator(
            kind: kind,
            score: nil,
            status: status,
            detail: reason,
            gap: PlantHealthIndicator.Gap(reason: reason, remedy: remedy)
        )
    }

    private static func visualReading(
        from finding: PlantVisualIndicatorFinding,
        at date: Date,
        version: String
    ) -> PlantHealthIndicatorReading {
        let severity = min(3, max(0, finding.severity))
        let status: String
        switch finding.state {
        case .good: status = "Good"
        case .watch: status = severity >= 2 ? "Needs attention" : "Watch"
        case .neutral: status = "Not flagged"
        case .unavailable: status = "Not measured"
        }
        let evidence = Array(finding.evidence.prefix(5))
        return PlantHealthIndicatorReading(
            kind: finding.kind,
            value: "\(finding.state.rawValue)-\(severity)",
            score: nil,
            status: status,
            detail: evidence.isEmpty
                ? "The photo analysis returned no visible evidence for this signal."
                : evidence.joined(separator: " · "),
            evidenceLevel: finding.state == .unavailable ? .unavailable : .observed,
            source: finding.state == .unavailable ? .none : .photoAnalysis,
            confidence: min(100, max(0, finding.confidence)),
            evidence: evidence,
            measuredAt: date,
            validUntil: Calendar.current.date(byAdding: .day, value: stateWindowDays, to: date),
            algorithmVersion: version
        )
    }

    private static func unavailableReading(
        kind: PlantHealthIndicatorKind,
        status: String,
        detail: String,
        at date: Date,
        version: String
    ) -> PlantHealthIndicatorReading {
        PlantHealthIndicatorReading(
            kind: kind,
            value: "unavailable",
            score: nil,
            status: status,
            detail: detail,
            evidenceLevel: .unavailable,
            source: .none,
            confidence: nil,
            evidence: [],
            measuredAt: date,
            validUntil: Calendar.current.date(byAdding: .day, value: stateWindowDays, to: date),
            algorithmVersion: version
        )
    }

    private static func durable(
        from indicator: PlantHealthIndicator,
        value: String,
        at date: Date,
        version: String
    ) -> PlantHealthIndicatorReading {
        PlantHealthIndicatorReading(
            kind: indicator.kind,
            value: indicator.gap == nil ? value : "unavailable",
            score: indicator.score,
            status: indicator.status,
            detail: indicator.detail,
            evidenceLevel: indicator.gap == nil ? (indicator.evidenceLevel ?? .estimated) : .unavailable,
            source: indicator.gap == nil ? (indicator.source ?? .legacyInference) : .none,
            confidence: indicator.confidence,
            evidence: [],
            measuredAt: date,
            validUntil: nil,
            algorithmVersion: version
        )
    }

    private static func display(_ reading: PlantHealthIndicatorReading) -> PlantHealthIndicator {
        if reading.evidenceLevel == .unavailable {
            let legacyVisualGap = reading.status == "Not measured"
                && [PlantHealthIndicatorKind.foliage, .posture, .growth].contains(reading.kind)
            let remedy: PlantHealthIndicator.Remedy? = switch reading.kind {
            case .moisture: .checkIn
            case .light: .setLight
            case .foliage, .posture, .growth: .checkIn
            case .care: .logCare
            }
            return noRead(
                reading.kind,
                status: legacyVisualGap ? "Not visible" : reading.status,
                reason: legacyVisualGap
                    ? "This scan couldn't clearly assess \(reading.kind.subject). Take a closer photo at your next check-in."
                    : reading.detail,
                remedy: remedy
            )
        }
        return PlantHealthIndicator(
            kind: reading.kind,
            score: reading.score,
            status: reading.status,
            detail: reading.detail,
            evidenceLevel: reading.evidenceLevel,
            source: reading.source,
            confidence: reading.confidence,
            recordedAt: reading.measuredAt,
            algorithmVersion: reading.algorithmVersion
        )
    }
}

/// Presentation only: missing evidence never becomes a poor-health score, and
/// a developing care history is not treated as a warning about the plant.
struct PlantHealthIndicatorPresentation {
    let indicator: PlantHealthIndicator

    var title: String {
        if indicator.kind == .moisture, indicator.gap?.remedy == .checkIn {
            return "Needs checking"
        }
        switch (indicator.kind, indicator.status) {
        case (.foliage, "Good"): return "Looking healthy"
        case (.light, "Good fit"): return "Suitable spot"
        case (.light, "Low fit"), (.light, "Fair fit"): return "Review its spot"
        case (_, "Watch"): return "Keep an eye on"
        default: return indicator.status
        }
    }

    var evidence: String {
        guard indicator.hasReading else { return "Nothing recorded yet" }
        switch indicator.evidenceLevel {
        case .measured: return "Measured"
        case .observed:
            return indicator.source == .photoAnalysis ? "Observed in photo" : "Observed"
        case .estimated: return "Estimated"
        case .unavailable: return "Unavailable"
        case nil: return "Source not recorded"
        }
    }

    var priority: Int {
        if indicator.gap != nil { return indicator.gap?.remedy == nil ? 4 : 1 }
        if ["Needs attention", "Watch", "Low fit", "Needs care", "Uneven"].contains(indicator.status) {
            return 0
        }
        if indicator.kind == .moisture, ["Dry", "Surface dry"].contains(indicator.status) { return 1 }
        if indicator.status == "Fair fit" { return 1 }
        return 3
    }

    static func prioritized(_ indicators: [PlantHealthIndicator]) -> [PlantHealthIndicator] {
        indicators.enumerated().sorted {
            let left = Self(indicator: $0.element).priority
            let right = Self(indicator: $1.element).priority
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
}

private struct PlantHealthIndicatorTile: View {
    let indicator: PlantHealthIndicator

    private var presentation: PlantHealthIndicatorPresentation {
        PlantHealthIndicatorPresentation(indicator: indicator)
    }

    private var tint: Color {
        if presentation.priority == 0 { return GroveTheme.warning }
        if indicator.gap != nil { return GroveTheme.mutedInk }
        return GroveTheme.accentStrong
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: indicator.kind.symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(indicator.kind == .moisture ? "Soil" : indicator.kind == .foliage ? "Leaves" : indicator.kind.label)
                    .foregroundStyle(GroveTheme.mutedInk)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(GroveTheme.subtleInk)
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.medium))

            Text(presentation.title)
                .font(.headline)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)

            Text(presentation.evidence)
                .font(.caption)
                .foregroundStyle(GroveTheme.mutedInk)
                .fixedSize(horizontal: false, vertical: true)

            if let remedy = indicator.gap?.remedy {
                Text(remedy.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GroveTheme.accentStrong)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(14)
        .background(GroveTheme.surface, in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                .stroke(GroveTheme.separator, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(indicator.kind.label): \(presentation.title)")
        .accessibilityValue(presentation.evidence)
        .accessibilityHint("Opens the details and available actions")
    }
}

// MARK: - One signal, in full

/// A single health signal, unpacked: what it is worth, what that was read
/// from, and the one thing that would fill it in.
///
/// This is where the six tiles put their prose. Grove now reads soil moisture
/// from the check-in photo and recorded waterings; the old "feel the soil"
/// three-word check is gone, so a moisture gap routes to a photo check-in.
private struct PlantHealthIndicatorSheet: View {
    let indicator: PlantHealthIndicator
    let plantID: UUID
    let onLogCare: (CareKind) -> Void

    @Environment(IntentRouter.self) private var intentRouter
    @Environment(\.dismiss) private var dismiss

    /// Everything the sheet sets in motion waits for the sheet to be gone.
    /// Logging care raises a toast, a repeat watering raises a question, and a
    /// remedy pushes a screen: all three land behind a sheet that is still
    /// animating away.
    @State private var routeOnExit: AppRoute?
    @State private var careOnExit: CareKind?

    private var tint: Color {
        guard let score = indicator.score else { return GroveTheme.subtleInk }
        return switch score {
        case 80...: GroveTheme.healthHealthy
        case 60..<80: GroveTheme.warning
        default: GroveTheme.healthAttention
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    reading

                    Text(indicator.detail)
                        .font(.subheadline)
                        .foregroundStyle(GroveTheme.mutedInk)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        GroveEyebrow(text: "What this reads")
                        Text(indicator.kind.readsFrom)
                            .font(.subheadline)
                            .foregroundStyle(GroveTheme.mutedInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if indicator.hasReading {
                        VStack(alignment: .leading, spacing: 6) {
                            GroveEyebrow(text: "Evidence")
                            Text(evidenceDescription)
                                .font(.subheadline)
                                .foregroundStyle(GroveTheme.mutedInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !indicator.potFacts.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            GroveEyebrow(text: "What the scan saw")
                            ForEach(indicator.potFacts) { fact in
                                HStack(alignment: .firstTextBaseline, spacing: 9) {
                                    Image(systemName: fact.symbol)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(fact.isAlarming ? GroveTheme.warning : GroveTheme.subtleInk)
                                        .frame(width: 14)
                                    Text(fact.text)
                                        .font(.subheadline)
                                        .foregroundStyle(fact.isAlarming ? GroveTheme.ink : GroveTheme.mutedInk)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .accessibilityIdentifier("plantIndicatorPotFacts")
                    }

                    if let remedy = indicator.gap?.remedy {
                        action(remedy)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .groveBackground()
            .navigationTitle(indicator.kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.bold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear {
            if let careOnExit { onLogCare(careOnExit) }
            if let routeOnExit { intentRouter.pushedRoute = routeOnExit }
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let score = indicator.score {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        GroveDisplayHeading(text: "\(score)", style: .title)
                            .monospacedDigit()
                        Text("%")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(GroveTheme.subtleInk)
                    }

                    Spacer(minLength: 8)

                    Text(indicator.status)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(tint.opacity(0.12), in: Capsule())
                } else {
                    GroveDisplayHeading(text: indicator.status, style: .section)
                }
            }

            if let score = indicator.score {
                GroveProgressBar(
                    fraction: Double(score) / 100,
                    tint: tint,
                    height: 10,
                    minimumFill: 0
                )
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var evidenceDescription: String {
        var parts: [String] = []
        switch indicator.evidenceLevel {
        case .measured: parts.append("Measured by an instrument")
        case .observed: parts.append(indicator.source == .ownerReport ? "Observed by you" : "Observed in the assessment photo")
        case .estimated: parts.append("Estimated from recorded context; not directly measured")
        case .unavailable, nil: break
        }
        if let confidence = indicator.confidence {
            parts.append("\(confidence)% assessment confidence")
        }
        if let recordedAt = indicator.recordedAt {
            parts.append(recordedAt.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func action(_ remedy: PlantHealthIndicator.Remedy) -> some View {
        switch remedy {
        case .checkIn:
            GroveCTAButton(title: "Check in") {
                routeOnExit = .checkIn(plantID)
                dismiss()
            }

        case .setLight:
            GroveCTAButton(title: "Set the spot") {
                routeOnExit = .editPlant(plantID)
                dismiss()
            }

        case .logCare:
            Menu {
                ForEach(CareKind.loggable, id: \.self) { kind in
                    Button {
                        careOnExit = kind
                        dismiss()
                    } label: {
                        Label(kind.logTitle, systemImage: kind.icon)
                    }
                }
            } label: {
                GroveInkLabel(title: "Log care", systemImage: "checkmark.circle")
            }
            .buttonStyle(GrovePressStyle())
        }
    }
}

// MARK: - Health chart

/// The plant's whole health history as one line, drawn on arrival.
private struct HealthTrendChart: View {
    let series: [(date: Date, score: Int)]
    let tint: Color
    var careEvents: [CareTask] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draw: CGFloat = 0

    /// The score range the chart is drawn against, clamped so a small wobble
    /// cannot fill the frame and be read as a collapse.
    ///
    /// The old window was `min - 5 … max + 5`, which on a settled plant could
    /// be as narrow as ten points — so three points of noise swept the full
    /// height of the card, unlabelled. `CheckInHealthCard` already solved this
    /// with a minimum span and a printed scale; this is the same rule, so the
    /// two charts in the product cannot disagree about how dramatic a change
    /// looks. Shared with the baseline state so the first point keeps its place
    /// when the second reading arrives.
    static func domain(for scores: [Int]) -> (low: Int, high: Int) {
        let smallest = scores.min() ?? 0
        let largest = scores.max() ?? 100
        let span = max(40, largest - smallest + 12)
        var low = max(0, (smallest + largest - span) / 2)
        var high = low + span
        if high > 100 {
            high = 100
            low = max(0, high - span)
        }
        return (low, high)
    }

    private var careMarkers: some View {
        GeometryReader { proxy in
            if let first = series.first, let last = series.last, last.date > first.date {
                ForEach(careEvents.filter { $0.performedAt >= first.date && $0.performedAt <= last.date }) { task in
                    let fraction = task.performedAt.timeIntervalSince(first.date) / last.date.timeIntervalSince(first.date)
                    VStack(spacing: 3) {
                        Rectangle().fill(tint.opacity(0.2)).frame(width: 1)
                        Image(systemName: task.kind.icon).font(.caption2).foregroundStyle(tint)
                    }
                    .frame(width: 18, height: proxy.size.height)
                    .position(x: max(9, min(proxy.size.width - 9, proxy.size.width * fraction)), y: proxy.size.height / 2)
                    .accessibilityLabel("\(task.kind.loggedTitle), \(task.performedAt.formatted(date: .abbreviated, time: .omitted))")
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var domain: (low: Int, high: Int) {
        Self.domain(for: series.map(\.score))
    }

    /// Positions in 0…1 on both axes: `x` by date, `y` by score within the
    /// clamped domain.
    private var points: [CGPoint] {
        let domain = domain
        let span = CGFloat(max(1, domain.high - domain.low))
        guard let first = series.first, let last = series.last else { return [] }
        let start = first.date.timeIntervalSince1970
        let elapsed = max(1, last.date.timeIntervalSince1970 - start)
        return series.map { point in
            CGPoint(
                x: CGFloat((point.date.timeIntervalSince1970 - start) / elapsed),
                y: CGFloat(point.score - domain.low) / span
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                ForEach([0.0, 0.5, 1.0], id: \.self) { level in
                    Rectangle()
                        .fill(GroveTheme.separator.opacity(0.7))
                        .frame(height: 1)
                        .frame(maxHeight: .infinity, alignment: level == 0 ? .top : (level == 0.5 ? .center : .bottom))
                }
                .accessibilityHidden(true)

                TrendLine(values: points, closed: true)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.26), tint.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .opacity(draw)

                TrendLine(values: points, closed: false)
                    .trim(from: 0, to: draw)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                careMarkers
                marks
            }
            .padding(.vertical, 10)
            .frame(height: 132)

            HStack {
                Text(series[0].date.formatted(.dateTime.day().month(.abbreviated)))
                Spacer(minLength: 8)
                // The scale, printed. Three unlabelled gridlines over an
                // auto-zoomed range asked the reader to trust a shape whose
                // magnitude they had no way to judge.
                Text("Scale \(domain.low)–\(domain.high)")
                Spacer(minLength: 8)
                // The real date of the last point. This said "Now" whatever the
                // series held, so a six-week-old reading was labelled as today's.
                Text(Self.rightAxisLabel(for: series[series.count - 1].date))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(GroveTheme.subtleInk)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .onAppear {
            guard draw == 0 else { return }
            if reduceMotion {
                draw = 1
            } else {
                withAnimation(.easeOut(duration: 0.9)) { draw = 1 }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health over time")
        .accessibilityValue(
            "\(series.count) scores, from \(series[0].score) on \(series[0].date.formatted(date: .abbreviated, time: .omitted)) to \(series[series.count - 1].score) on \(series[series.count - 1].date.formatted(date: .abbreviated, time: .omitted)). Scale \(domain.low) to \(domain.high)."
        )
    }

    /// Today, or the date the last reading was actually taken.
    private static func rightAxisLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Now" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// A dot per reading, and a ring on the newest.
    ///
    /// These used to disappear entirely above eight readings — directly under a
    /// comment saying a line with no marks hides how many readings it is built
    /// from — so the user with the most history got the least legible chart.
    /// They shrink instead.
    private var marks: some View {
        GeometryReader { proxy in
            let count = points.count
            let size: CGFloat = count > 14 ? 5 : (count > 8 ? 6 : 7)
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                let isLast = index == count - 1
                Circle()
                    .fill(isLast ? tint : GroveTheme.surface)
                    .overlay { Circle().stroke(tint, lineWidth: isLast ? 3 : 2) }
                    .frame(width: isLast ? 11 : size, height: isLast ? 11 : size)
                    .position(
                        x: point.x * proxy.size.width,
                        y: proxy.size.height - point.y * proxy.size.height
                    )
                    .opacity(draw == 1 ? 1 : 0)
                    .animation(.easeOut(duration: 0.25).delay(0.55), value: draw)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The health line before there is a line: the first reading, placed where it
/// will sit on the chart that follows, and a dashed run toward the point the
/// next check-in adds.
///
/// This replaced a 48 pt score dial beside the sentence "each check-in adds a
/// point to this line" — a number the card above had already shown, next to a
/// line the reader could not see. The mechanic belongs in the chart, not in
/// prose, so the first state of "Health over time" is the chart's own opening
/// frame instead of a paragraph about one.
private struct PlantHealthBaseline: View {
    let reading: PlantPageProgress.Reading
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draw: CGFloat = 0

    private var domain: (low: Int, high: Int) {
        HealthTrendChart.domain(for: [reading.score])
    }

    /// The reading's height in 0…1 within the shared chart domain.
    private var scoreLevel: CGFloat {
        let span = CGFloat(max(1, domain.high - domain.low))
        return CGFloat(reading.score - domain.low) / span
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                // The first point sits fully inside the frame; the full chart's
                // marks centre on the edge and deliberately overhang it.
                let start = CGPoint(x: 6, y: proxy.size.height - scoreLevel * proxy.size.height)
                let end = CGPoint(x: proxy.size.width - 6, y: start.y)
                ZStack(alignment: .topLeading) {
                    gridlines
                    Path { path in
                        path.move(to: start)
                        path.addLine(to: CGPoint(x: end.x - 6, y: end.y))
                    }
                    .trim(from: 0, to: draw)
                    .stroke(tint.opacity(0.4), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [5, 6]))
                    Circle()
                        .stroke(tint.opacity(0.4), lineWidth: 2)
                        .frame(width: 9, height: 9)
                        .position(end)
                    Circle()
                        .fill(tint)
                        .overlay { Circle().stroke(GroveTheme.surface, lineWidth: 3) }
                        .frame(width: 11, height: 11)
                        .position(start)
                        .opacity(draw == 1 ? 1 : 0)
                }
            }
            .padding(.vertical, 10)
            .frame(height: 132)

            HStack {
                Text("First check-in · \(reading.date.formatted(.dateTime.day().month(.abbreviated)))")
                Spacer(minLength: 8)
                Text("Each check-in adds a point")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(GroveTheme.subtleInk)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .onAppear {
            guard draw == 0 else { return }
            if reduceMotion {
                draw = 1
            } else {
                withAnimation(.easeOut(duration: 0.8)) { draw = 1 }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Health over time")
        .accessibilityValue(
            "One check-in, \(reading.score) on \(reading.date.formatted(date: .abbreviated, time: .omitted)). Each check-in adds a point."
        )
    }

    private var gridlines: some View {
        ForEach([0.0, 0.5, 1.0], id: \.self) { position in
            Rectangle()
                .fill(GroveTheme.separator.opacity(0.7))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: position == 0 ? .top : (position == 0.5 ? .center : .bottom))
        }
        .accessibilityHidden(true)
    }
}

/// A smoothed line through normalised values, optionally closed down to the
/// baseline so it can be filled.
/// A line through points already positioned in 0…1 on both axes.
///
/// `x` used to be the reading's *index*, so two check-ins a day apart occupied
/// the same width as two a season apart and a recovery window of daily looks was
/// drawn as wide as the fortnights before it. The axis is date-based so the
/// spacing reflects the actual time between readings.
private struct TrendLine: Shape {
    /// Unit positions, `x` and `y` both 0…1, left to right.
    let values: [CGPoint]
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        let points = values.map { value in
            CGPoint(
                x: rect.minX + value.x * rect.width,
                y: rect.maxY - value.y * rect.height
            )
        }

        path.move(to: points[0])
        if points.count == 2 {
            path.addLine(to: points[1])
        } else {
            for index in 1..<(points.count - 1) {
                let mid = CGPoint(
                    x: (points[index].x + points[index + 1].x) / 2,
                    y: (points[index].y + points[index + 1].y) / 2
                )
                path.addQuadCurve(to: mid, control: points[index])
            }
            path.addLine(to: points[points.count - 1])
        }

        if closed {
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
            path.addLine(to: CGPoint(x: points[0].x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - What's next

/// The decision Grove owes the owner immediately after showing them a score.
///
/// A scheduled soil look and a scheduled photo look already exist on day zero;
/// the old page made someone cross six diagnostic sections before it admitted
/// either one. This small value type keeps the priority and timing testable
/// without making the view own a second model.
struct PlantPageHandoff: Equatable {
    /// Where the card's primary button goes, and what it says.
    ///
    /// Nil when the handoff is a statement rather than an errand. A card that
    /// always carried a button had to invent somewhere to send people, and the
    /// place it invented was a photo check-in the plant did not need.
    struct Action: Equatable {
        let title: String
        let route: AppRoute
    }

    /// Where this handoff came from.
    ///
    /// The page has three other places that already carry a schedule: the
    /// check-in card, the docked bar, and the care queue. A handoff that only
    /// restates a due task earns no card of its own — it becomes a third
    /// "Check in" button stacked on the two that were already there.
    enum Source: Equatable {
        /// A recovery plan from a diagnosis.
        case diagnosis
        /// An instruction the assessment produced for this plant.
        case assessedAction
        /// A task that is due, which the check-in card and dock already offer.
        case dueTask
        /// Nothing is being asked for.
        case schedule

        /// Whether this is worth a card the rest of the page cannot provide.
        var deservesItsOwnCard: Bool { self == .diagnosis || self == .assessedAction }
    }

    /// What the eyebrow means, so the card can colour it from the semantic
    /// palette instead of matching on its own copy.
    enum Tone: Equatable {
        /// Something is wrong now.
        case urgent
        /// Worth watching, nothing is on fire.
        case caution
        /// A normal errand.
        case routine
        /// Nothing is being asked for.
        case calm
    }

    let eyebrow: String
    let title: String
    let detail: String
    let primaryTask: CareTask?
    let followUp: String?
    let recommendation: String?
    let action: Action?
    let tone: Tone
    let source: Source

    static func make(
        plant: Plant,
        dueCare: [CareTask],
        diagnosis: PlantDiagnosis? = nil,
        now: Date = .now
    ) -> PlantPageHandoff {
        let ordered = dueCare.sorted { $0.dueDate < $1.dueDate }
        let firstTask = ordered.first
        let firstAction = plant.nextActions.first

        // A diagnosis outranks everything else on the page. Someone who
        // photographed a collapsing plant came for the recovery plan, and it
        // used to live three taps down behind an overflow menu.
        if let diagnosis, diagnosis.healthBand.needsAttention,
           diagnosis.actionability == nil || diagnosis.actionability == .actionable,
           let recovery = diagnosis.actionsToTake.first {
            return PlantPageHandoff(
                eyebrow: diagnosis.healthBand == .urgent ? "Act now" : "Do this first",
                title: recovery,
                detail: diagnosis.summary,
                primaryTask: nil,
                followUp: firstTask.map { scheduleLine(prefix: "Next", task: $0, now: now) },
                recommendation: nil,
                action: Action(title: "Open recovery plan", route: .plantDiagnosis(diagnosis.id)),
                tone: diagnosis.healthBand == .urgent ? .urgent : .caution,
                source: .diagnosis
            )
        }

        if [.monitor, .attention, .urgent].contains(plant.healthBand), let firstAction {
            let eyebrow = switch plant.healthBand {
            case .urgent: "Act now"
            case .attention: "Do this first"
            case .monitor: "Keep an eye on"
            case .thriving, .healthy: "Today"
            }
            let primaryTask = firstTask.flatMap {
                daysUntil($0.dueDate, from: now) <= 0 ? $0 : nil
            }
            let nextTask = primaryTask == nil ? firstTask : ordered.dropFirst().first
            return PlantPageHandoff(
                eyebrow: eyebrow,
                title: firstAction,
                detail: plant.summary,
                primaryTask: primaryTask,
                followUp: nextTask.map { scheduleLine(prefix: "Next", task: $0, now: now) },
                recommendation: nil,
                action: primaryTask.map { Action(title: $0.kind.title, route: .careTask($0.id)) },
                tone: plant.healthBand == .urgent ? .urgent : .caution,
                source: .assessedAction
            )
        }

        if let firstTask, daysUntil(firstTask.dueDate, from: now) <= 0 {
            let isOverdue = daysUntil(firstTask.dueDate, from: now) < 0
            return PlantPageHandoff(
                eyebrow: isOverdue ? "Overdue" : "Today",
                title: firstTask.kind.title,
                detail: firstTask.detail,
                primaryTask: firstTask,
                followUp: ordered.dropFirst().first.map {
                    scheduleLine(prefix: "Then", task: $0, now: now)
                },
                recommendation: firstAction,
                action: Action(title: firstTask.kind.title, route: .careTask(firstTask.id)),
                tone: isOverdue ? .caution : .routine,
                source: .dueTask
            )
        }

        // An assessed instruction leads over the schedule, even when the
        // schedule is empty for today. "Nothing needs doing today" was the
        // first thing a new owner read on the day they added their plant,
        // while the scan's own "feel the top 3 cm before you water" sat
        // unread in the record. Advice the plant came with is not nothing.
        if let firstAction {
            return PlantPageHandoff(
                eyebrow: "Do this first",
                title: firstAction,
                detail: plant.summary,
                primaryTask: nil,
                followUp: firstTask.map { scheduleLine(prefix: "Next", task: $0, now: now) },
                recommendation: nil,
                action: nil,
                tone: .routine,
                source: .assessedAction
            )
        }

        if let firstTask {
            return PlantPageHandoff(
                eyebrow: "Today",
                title: "Nothing needs doing today",
                detail: scheduleLine(prefix: "Next", task: firstTask, now: now),
                primaryTask: nil,
                followUp: ordered.dropFirst().first.map {
                    scheduleLine(prefix: "Then", task: $0, now: now)
                },
                recommendation: nil,
                action: nil,
                tone: .calm,
                source: .schedule
            )
        }

        return PlantPageHandoff(
            eyebrow: "Today",
            title: "Nothing needs doing today",
            detail: "The next check-in will appear here when it's due.",
            primaryTask: nil,
            followUp: nil,
            recommendation: nil,
            action: nil,
            tone: .calm,
            source: .schedule
        )
    }

    private static func daysUntil(_ date: Date, from now: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    private static func scheduleLine(prefix: String, task: CareTask, now: Date) -> String {
        let days = daysUntil(task.dueDate, from: now)
        let action: String = switch task.kind {
        case .checkIn: "take a fresh photo"
        case .inspectSoil: "take a fresh photo"
        case .water: "review watering"
        case .fertilise: "review feeding"
        case .rotate: "turn the pot"
        case .cleanLeaves: "clean the leaves"
        case .treat: "review the treatment"
        case .prune: "check the damaged growth"
        case .repot: "review the pot"
        case .relocate: "review the new spot"
        case .monitor: "look for the expected change"
        }
        let timing: String
        switch days {
        case ..<0:
            timing = "now"
        case 0:
            timing = "today"
        case 1:
            timing = "tomorrow, \(dateLabel(task.dueDate))"
        default:
            timing = "on \(dateLabel(task.dueDate))"
        }
        return "\(prefix): \(action) \(timing)."
    }

    private static func dateLabel(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}
