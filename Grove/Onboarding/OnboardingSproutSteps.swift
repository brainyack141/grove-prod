import CoreLocation
import SwiftUI

// MARK: - Room

/// "Which room is it in?" The scene changes with the answer and the room tag
/// lands on the plant card, then the answer is written onto the staged plant,
/// so it arrives in the account already filed under that room on Today's map.
struct OnboardingRoomStepView: View {
    let model: OnboardingModel

    @State private var plant: OnboardingFirstPlantPresentation?
    @State private var selection: OnboardingRoom?
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        OnboardingSproutPage(
            step: 2,
            isBackEnabled: !isSaving,
            onBack: model.back,
            trailing: isSaving ? nil : ("Skip", { model.advance() })
        ) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingQuestionTitle(
                    lead: "Which ",
                    accent: "room",
                    trail: " is it in?",
                    subtitle: "It goes on that room in Today’s map."
                )
                OnboardingPlantCard(plant: plant, room: selection)
                RoomScene(room: selection ?? .livingRoom)
                    .id(selection ?? .livingRoom)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .opacity(selection == nil ? 0.55 : 1)
                GroveFlowLayout(spacing: 8) {
                    ForEach(OnboardingRoom.allCases) { room in
                        roomChip(room)
                    }
                }
                if let saveError {
                    Text(saveError)
                        .font(.callout)
                        .foregroundStyle(GroveTheme.danger)
                }
            }
        } footer: {
            OnboardingPrimaryButton(title: isSaving ? "Saving…" : "Continue", isEnabled: selection != nil && !isSaving) {
                save()
            }
            .accessibilityIdentifier("onboardingRoomContinue")
        }
        .task { await restore() }
    }

    private func roomChip(_ room: OnboardingRoom) -> some View {
        GroveRoomChip(title: room.title, isSelected: selection == room) {
            selection = room
        }
    }

    private func restore() async {
        plant = await OnboardingFirstPlantPresentation.load()
        if let room = plant?.assignedRoom { selection = OnboardingRoom(rawValue: room) }
    }

    private func save() {
        guard let selection, !isSaving else { return }
        isSaving = true
        saveError = nil
        Task {
            do {
                guard let draft = try await PendingFirstPlantStore.shared.loadUnclaimed() else {
                    model.recoverMissingFirstPlant()
                    return
                }
                try await PendingFirstPlantStore.shared.updateDetails(
                    nickname: draft.nickname,
                    location: selection.title,
                    lightPlacement: draft.lightPlacement
                )
                Haptics.commit()
                model.advance()
            } catch {
                saveError = "That room couldn’t be saved. Try again."
            }
            isSaving = false
        }
    }
}

// MARK: - Home

/// Where the grove lives, asked under the sky of the hour. "Use my location"
/// asks iOS once, then the sky and the numbers become that town's real weather
/// and daylight. Typing a town, or skipping, are always there.
struct OnboardingHomeStepView: View {
    @Bindable var model: OnboardingModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var plant: OnboardingFirstPlantPresentation?
    @State private var locationManager = GroveLocationManager()
    @State private var weather = WeatherService()
    @State private var isResolving = false
    @State private var message: String?
    @State private var showsTownSearch = false

    var body: some View {
        let sky = SproutWorld.sky(hour: localHour)
        VStack(spacing: 0) {
            OnboardingSegmentBar(
                step: 3,
                isBackEnabled: !isLocating,
                onSky: true,
                onBack: model.back,
                trailing: ("Skip", { model.advance() })
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    OnboardingQuestionTitle(
                        lead: "Where’s ",
                        accent: "home",
                        trail: "?",
                        subtitle: "Watering changes with the weather and daylight where your plants live.",
                        onSky: true
                    )
                    OnboardingPlantCard(
                        plant: plant,
                        room: plant?.assignedRoom.flatMap(OnboardingRoom.init(rawValue:)),
                        home: model.location?.townName
                    )
                    weatherCard
                    if let message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(SproutWorld.onSky)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        footer
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, GroveTheme.pagePadding + 4)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !dynamicTypeSize.isAccessibilitySize {
                footer
                    .padding(.horizontal, GroveTheme.pagePadding + 4)
                    .padding(.bottom, 8)
                    .padding(.top, 12)
                    .background {
                        ZStack {
                            sky.colors.last ?? .black
                            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.32)], startPoint: .top, endPoint: .bottom)
                        }
                        .ignoresSafeArea(edges: .bottom)
                    }
            }
        }
        .background {
            ZStack {
                LinearGradient(colors: sky.colors, startPoint: .top, endPoint: .bottom)
                if sky.isNight { stars }
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.6), value: localHour)
        }
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showsTownSearch) {
            NavigationStack { GroveLocationPickerView(onboardingModel: model) }
                .environment(\.colorScheme, .light)
        }
        .task { plant = await OnboardingFirstPlantPresentation.load() }
        // Keyed on the location so a town chosen in the picker sheet, or by the
        // location button, gets its forecast too; a one-shot task only covered
        // a location restored from the draft.
        .task(id: model.location) {
            guard let location = model.location else { return }
            message = nil
            await weather.load(for: location.coordinate)
        }
        .onChange(of: locationManager.lastCoordinate.map { "\($0.latitude),\($0.longitude)" }) { _, _ in
            guard let coordinate = locationManager.lastCoordinate else { return }
            Task { await choose(coordinate) }
        }
        .onChange(of: locationManager.status) { _, status in
            switch status {
            case .denied:
                message = "Location is off for Grove. Type your town instead."
                showsTownSearch = true
            case .failed:
                message = "Your location couldn’t be found. Type your town instead."
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            if model.location == nil {
                Button {
                    Haptics.commit()
                    message = nil
                    locationManager.requestCurrentLocation()
                } label: {
                    skyCapsule(isLocating ? "Finding your town…" : "Use my location")
                }
                .buttonStyle(GrovePressStyle())
                .disabled(isLocating)
                .accessibilityIdentifier("onboardingUseLocation")
                Button {
                    Haptics.tap()
                    showsTownSearch = true
                } label: {
                    skyOutlineCapsule("Type a town instead")
                }
                .buttonStyle(GrovePressStyle())
                .disabled(isLocating)
                .accessibilityIdentifier("onboardingTypeTown")
                Label("Used only for local weather and daylight. Never shown to friends.", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(SproutWorld.onSky.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            } else {
                Button {
                    Haptics.commit()
                    model.advance()
                } label: {
                    skyCapsule("Continue")
                }
                .buttonStyle(GrovePressStyle())
                .accessibilityIdentifier("onboardingHomeContinue")
                OnboardingQuietButton(title: "Change town", color: SproutWorld.onSky) { showsTownSearch = true }
            }
        }
    }

    /// The primary capsule turned over for the sky: light, with ink type.
    private func skyCapsule(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(GroveTheme.inkOnLight)
            .frame(maxWidth: .infinity, minHeight: OnboardingTheme.controlHeight)
            .background(SproutWorld.onSky, in: Capsule())
            .contentShape(Capsule())
    }

    /// The secondary choice drawn as an outline so it reads as an equal option,
    /// not a footnote.
    private func skyOutlineCapsule(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(SproutWorld.onSky)
            .frame(maxWidth: .infinity, minHeight: OnboardingTheme.controlHeight)
            .overlay { Capsule().stroke(SproutWorld.onSky.opacity(0.85), lineWidth: 1.5) }
            .contentShape(Capsule())
    }

    private var stars: some View {
        Canvas { context, size in
            let points: [(CGFloat, CGFloat, CGFloat)] = [(0.12, 0.22, 1.6), (0.3, 0.12, 1.2), (0.82, 0.18, 1.8), (0.7, 0.32, 1.2), (0.5, 0.08, 1.2), (0.92, 0.42, 1.4), (0.2, 0.4, 1.1)]
            for (x, y, r) in points {
                context.fill(Path(ellipseIn: CGRect(x: x * size.width, y: y * size.height, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.8)))
            }
        }
        .allowsHitTesting(false)
    }

    /// Before a place is known, three things a town will tell Grove. After, the
    /// town's own numbers.
    private var weatherCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let location = model.location {
                Text(cardHeading(location))
                    .font(.caption2.weight(.semibold))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(SproutWorld.onSky.opacity(0.8))
                if case .loaded(let forecast) = weather.phase {
                    HStack(alignment: .top, spacing: 10) {
                        stat(
                            forecast.current.map { "\($0.temperature(metric: usesMetric))°" } ?? "–",
                            forecast.current.map { _ in "now" } ?? "no reading"
                        )
                        if let today = forecast.sunlight.last {
                            stat(Self.hoursMinutes(today.daylightHours), "of daylight")
                            stat(Self.hoursMinutes(today.fullSunHours), "of full sun")
                        }
                    }
                    if let trend = daylightTrend(forecast) {
                        Divider().overlay(SproutWorld.onSky.opacity(0.3))
                        Text(trend)
                            .font(.subheadline)
                            .foregroundStyle(SproutWorld.onSky)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if weather.phase == .failed {
                    Text("The forecast isn’t available right now. Today will show it once it is.")
                        .font(.subheadline)
                        .foregroundStyle(SproutWorld.onSky)
                } else {
                    ProgressView().tint(SproutWorld.onSky)
                }
            } else {
                benefit("cloud.sun.fill", "This week’s forecast, so watering fits the weather")
                benefit("sun.horizon.fill", "Hours of daylight as the seasons turn")
                benefit("thermometer.snowflake", "A heads-up when frost or heat is on the way")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GroveTheme.cardRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.28), lineWidth: 1.5)
        }
        .animation(GroveMotion.reveal, value: weather.phase)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.weight(.heavy))
                .monospacedDigit()
                .foregroundStyle(SproutWorld.onSky)
            Text(label)
                .font(.footnote)
                .foregroundStyle(SproutWorld.onSky.opacity(0.8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func benefit(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.multicolor)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(SproutWorld.onSky)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func cardHeading(_ location: GroveLocation) -> String {
        let part = switch localHour {
        case 5..<12: "this morning"
        case 12..<17: "this afternoon"
        case 17..<21: "this evening"
        default: "tonight"
        }
        return "\(location.townName), \(part)"
    }

    /// Comparing today's daylight with a week ago says which way the season is
    /// turning, which is what changes how often a houseplant drinks.
    private func daylightTrend(_ forecast: GroveForecast) -> String? {
        let days = forecast.sunlight
        guard days.count >= 8, let today = days.last else { return nil }
        let weekAgo = days[days.count - 8]
        let change = today.daylightHours - weekAgo.daylightHours
        guard abs(change) >= 0.1 else { return nil }
        let name = plant?.displayName ?? "your plant"
        return change < 0
            ? "Days are getting shorter here, so \(name) will need water a little less often."
            : "Days are getting longer here, so \(name) will need water a little more often."
    }

    private var localHour: Int {
        var calendar = Calendar.current
        if case .loaded(let forecast) = weather.phase, let zone = forecast.current?.timeZone {
            calendar.timeZone = zone
        } else if let identifier = model.location?.timeZoneIdentifier, let zone = TimeZone(identifier: identifier) {
            calendar.timeZone = zone
        }
        return calendar.component(.hour, from: .now)
    }

    private var usesMetric: Bool {
        Locale.current.measurementSystem != .us
    }

    private var isLocating: Bool {
        locationManager.status == .locating || isResolving
    }

    static func hoursMinutes(_ hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    private func choose(_ coordinate: CLLocationCoordinate2D) async {
        isResolving = true
        defer { isResolving = false }
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(
                CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            )
            guard let place = placemarks.first else { throw CLError(.geocodeFoundNoResult) }
            let label = [place.locality ?? place.administrativeArea, place.country]
                .compactMap { $0 }
                .joined(separator: ", ")
            withAnimation(GroveMotion.reveal) {
                model.location = GroveLocation(
                    coordinate: coordinate,
                    label: label,
                    countryCode: place.isoCountryCode,
                    timeZoneIdentifier: place.timeZone?.identifier
                )
            }
            model.persistDraft()
            Haptics.success()
        } catch {
            message = "That place couldn’t be named. Type your town instead."
        }
    }
}

extension GroveLocation {
    /// "London" from "London, United Kingdom": the town alone, for tags.
    var townName: String {
        label.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? label
    }
}

// MARK: - First week

/// The last first-run screen: the plan the answers built, as a short timeline
/// of what happens next, then "Finish setup". Reminders are asked for over this
/// page, where the person can see exactly which day they are for.
struct OnboardingFirstWeekView: View {
    @Environment(GroveStore.self) private var store
    @Environment(NotificationService.self) private var notifications
    let plant: Plant
    let reminderHour: Int
    let onFinish: () -> Void

    @State private var showsReminderSheet = false
    @State private var isRequesting = false
    @State private var joinedAt = Date.now

    private var preview: OnboardingReminderPreview {
        OnboardingReminderPreview(plant: plant, task: store.nextPendingTask(for: plant.id), reminderHour: reminderHour)
    }

    var body: some View {
        OnboardingSproutPage {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom) {
                    Spacer()
                    SproutImage(pose: .cheer, size: 120)
                        .onAppear { Haptics.celebrate() }
                }
                .padding(.bottom, -18)
                OnboardingQuestionTitle(
                    lead: "",
                    accent: "Day 1.",
                    trail: " Here’s \(plant.nickname)’s first week.",
                    subtitle: "You can change any of this later."
                )
                RaisedPlate(radius: GroveTheme.cardRadius) {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { Divider().padding(.leading, 64) }
                            timelineRow(row)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } footer: {
            OnboardingPrimaryButton(title: "Finish setup") {
                Haptics.commit()
                if notifications.authorization == .notDetermined {
                    showsReminderSheet = true
                } else {
                    onFinish()
                }
            }
            .accessibilityIdentifier("onboardingFinishSetup")
        }
        .sheet(isPresented: $showsReminderSheet) {
            reminderSheet
                .presentationDetents([.height(440)])
                .presentationCornerRadius(34)
                .interactiveDismissDisabled(isRequesting)
        }
        .accessibilityIdentifier("firstPlantNotificationPrimer")
    }

    private struct Row {
        let symbol: String
        let color: Color
        let time: String
        let title: String
        let isDone: Bool
    }

    private var rows: [Row] {
        var rows = [Row(
            symbol: "leaf.fill",
            color: GroveTheme.accent,
            time: "Today, \(joinedAt.formatted(.dateTime.hour().minute()))",
            title: "\(plant.nickname) joined your grove",
            isDone: true
        )]
        let room = plant.location.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRoom = !room.isEmpty && room.caseInsensitiveCompare("Unassigned") != .orderedSame
        let town = store.profile.location?.townName
        if hasRoom || town != nil {
            let place = [hasRoom ? room : nil, town].compactMap { $0 }.joined(separator: " · ")
            rows.append(Row(
                symbol: "house.fill",
                color: SproutWorld.roomTint(OnboardingRoom(rawValue: room) ?? .livingRoom).glyph,
                time: place,
                title: town == nil ? "Placed in its room" : "Placed and matched to local weather",
                isDone: true
            ))
        }
        rows.append(Row(
            symbol: "drop.fill",
            color: SproutWorld.roomTint(.bathroom).glyph,
            time: preview.deliveryDescription,
            title: preview.title,
            isDone: false
        ))
        let checkIn = plant.nextCheckIn
        if !Calendar.current.isDate(checkIn, inSameDayAs: preview.deliveryDate) {
            rows.append(Row(
                symbol: "camera.fill",
                color: SproutWorld.roomTint(.office).glyph,
                time: checkIn.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)),
                title: "First check-in photo",
                isDone: false
            ))
        }
        return rows
    }

    private func timelineRow(_ row: Row) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(row.color, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(row.time)
                    .font(.footnote)
                    .foregroundStyle(GroveTheme.mutedInk)
                Text(row.title)
                    .font(.headline)
                    .foregroundStyle(GroveTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: row.isDone ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(row.isDone ? GroveTheme.accent : GroveTheme.separator)
                .accessibilityLabel(row.isDone ? "Done" : "Coming up")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    /// The real first reminder, the day it lands, and the choice.
    private var reminderSheet: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image("GroveAppIconPreview")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(preview.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Spacer(minLength: 6)
                        Text(preview.deliveryDate.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                            .font(.caption)
                            .foregroundStyle(GroveTheme.mutedInk)
                    }
                    Text(preview.body).font(.footnote).lineLimit(3)
                }
                .foregroundStyle(GroveTheme.ink)
            }
            .padding(12)
            .background(GroveTheme.secondarySurface.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Reminder preview. \(preview.title). \(preview.body)")

            VStack(spacing: 6) {
                (Text("Don’t miss ") + Text(reminderDay).foregroundStyle(GroveTheme.accent) + Text("."))
                    .font(GroveTheme.display(24, weight: .bold))
                    .foregroundStyle(GroveTheme.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("One notification on the day a plant needs you.")
                    .font(.subheadline)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)

            Spacer(minLength: 16)

            VStack(spacing: 4) {
                Button {
                    isRequesting = true
                    Task {
                        await notifications.requestAuthorization()
                        isRequesting = false
                        showsReminderSheet = false
                        onFinish()
                    }
                } label: {
                    OnboardingInkCapsuleLabel(title: isRequesting ? "Asking iOS…" : "Turn on reminders", isWorking: isRequesting)
                }
                .buttonStyle(GrovePressStyle())
                .disabled(isRequesting)
                .accessibilityIdentifier("enableFirstPlantNotifications")
                OnboardingQuietButton(title: "Not now") {
                    showsReminderSheet = false
                    onFinish()
                }
                .disabled(isRequesting)
                .accessibilityIdentifier("skipFirstPlantNotifications")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .background(GroveTheme.surface)
    }

    /// "Thursday", or "today" / "tomorrow" when the reminder is that close.
    private var reminderDay: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(preview.deliveryDate) { return "today" }
        if calendar.isDateInTomorrow(preview.deliveryDate) { return "tomorrow" }
        return preview.deliveryDate.formatted(.dateTime.weekday(.wide))
    }
}
