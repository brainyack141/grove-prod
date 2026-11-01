import SwiftUI
import UIKit

/// The permission primer shown after a user's first plant has a baseline.
///
/// The primer explains the value in Grove's own language before iOS presents
/// the system permission alert. It stays skippable, and the app continues to
/// work when the user chooses not to allow notifications.
struct OnboardingNotificationPrimerView: View {
    @Environment(GroveStore.self) private var store
    let plant: Plant
    let task: CareTask?
    @Binding var reminderHour: Int
    let isRequesting: Bool
    var enableTitle: String = "Enable reminders"
    let onEnable: () -> Void
    let onSkip: () -> Void

    private var preview: OnboardingReminderPreview {
        OnboardingReminderPreview(
            plant: plant,
            task: task,
            reminderHour: reminderHour
        )
    }

    private var reminderTimeLabel: some View {
        Label(preview.deliveryDescription, systemImage: "clock.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(GroveTheme.accentStrong)
    }

    private var reminderHourPicker: some View {
        Picker("Reminder time", selection: $reminderHour) {
            ForEach(0..<24, id: \.self) { hour in
                Text(Self.hourLabel(hour)).tag(hour)
            }
        }
        .pickerStyle(.menu)
        .tint(GroveTheme.accentStrong)
        .disabled(isRequesting)
        .accessibilityIdentifier("primerReminderHourPicker")
    }

    private static func hourLabel(_ hour: Int) -> String {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: .now)
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: startOfDay) ?? startOfDay
        return date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let url = store.latestPhotoURL(for: plant.id) {
                    Group {
                        if url.isFileURL, let photo = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: photo).resizable().scaledToFill()
                        } else {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "leaf").font(.largeTitle)
                            }
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .padding(.bottom, 20)
                    .accessibilityHidden(true)
                }

                VStack(spacing: 12) {
                    GroveDisplayHeading(
                        text: "A little help staying on top of care.",
                        style: .heading
                    )
                    .multilineTextAlignment(.center)

                    Text("Get reminders when your plants need attention.")
                    .font(.body)
                    .foregroundStyle(GroveTheme.mutedInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "leaf.fill")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(GroveTheme.onCanvasButtonLabel)
                                .frame(width: 28, height: 28)
                                .background(GroveTheme.accentStrong, in: Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preview.title)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(GroveTheme.ink)
                                Text(preview.body)
                                    .font(.footnote)
                                    .foregroundStyle(GroveTheme.mutedInk)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Divider()

                        // The time is chosen here, where the person decides about
                        // reminders, not buried in Settings; it writes the same
                        // stored preference Settings uses.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                reminderTimeLabel
                                Spacer(minLength: 8)
                                reminderHourPicker
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                reminderTimeLabel
                                reminderHourPicker
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GroveTheme.surface,
                        in: RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: GroveTheme.insetRadius, style: .continuous)
                            .stroke(GroveTheme.separator, lineWidth: 1)
                    }

                }
                .frame(maxWidth: 360)
                .padding(.horizontal, GroveTheme.pagePadding)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 34)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                Button(action: onEnable) {
                    GroveCTALabel(
                        title: isRequesting ? "Asking iOS…" : enableTitle,
                        systemImage: isRequesting ? "hourglass" : "bell.badge.fill"
                    )
                }
                .buttonStyle(GrovePressStyle())
                .disabled(isRequesting)
                .opacity(isRequesting ? 0.6 : 1)
                .accessibilityIdentifier("enableFirstPlantNotifications")

                Button("Not now", action: onSkip)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GroveTheme.mutedInk)
                    .disabled(isRequesting)
                    .accessibilityIdentifier("skipFirstPlantNotifications")
            }
            .groveActionBar()
        }
        .background(OnboardingTheme.base.ignoresSafeArea())
        .toolbar(.hidden, for: .tabBar)
        .accessibilityIdentifier("firstPlantNotificationPrimer")
    }
}

/// A single source of truth for the primer's lock-screen preview. It uses the
/// same task copy and delivery-date calculation as `NotificationService`, so
/// the permission screen cannot promise a later generic check-in while Grove
/// has an earlier soil task queued.
struct OnboardingReminderPreview: Equatable {
    let title: String
    let body: String
    let deliveryDate: Date
    let deliveryDescription: String

    init(
        plant: Plant,
        task: CareTask?,
        reminderHour: Int,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        if let task {
            let copy = GroveReminderCopy.forCare(task: task, plant: plant)
            title = copy.title
            body = copy.body
            deliveryDate = NotificationService.reminderDate(
                for: task.dueDate,
                now: now,
                hour: reminderHour
            ) ?? task.dueDate
            deliveryDescription = Self.deliveryDescription(
                for: deliveryDate,
                now: now,
                calendar: calendar
            )
        } else {
            title = "Check in on \(plant.nickname)"
            body = "Check in and note what has changed."
            deliveryDate = NotificationService.reminderDate(
                for: plant.nextCheckIn,
                now: now,
                hour: reminderHour
            ) ?? plant.nextCheckIn
            deliveryDescription = Self.deliveryDescription(
                for: deliveryDate,
                now: now,
                calendar: calendar
            )
        }
    }

    static func firstTask(for plant: Plant, in tasks: [CareTask]) -> CareTask? {
        tasks
            .filter { !$0.isCompleted && $0.plantID == plant.id }
            .min { $0.dueDate < $1.dueDate }
    }

    private static func deliveryDescription(
        for date: Date,
        now: Date,
        calendar: Calendar
    ) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today at \(time)"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow at \(time)"
        }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
    }
}

#Preview {
    OnboardingNotificationPrimerView(
        plant: .notificationPreview,
        task: nil,
        reminderHour: .constant(9),
        isRequesting: false,
        onEnable: {},
        onSkip: {}
    )
}

private extension Plant {
    static var notificationPreview: Plant {
        Plant(
            id: UUID(),
            nickname: "Monty",
            species: "Swiss cheese plant",
            scientificName: "Monstera deliciosa",
            location: "Living room",
            healthScore: 92,
            healthBand: .thriving,
            trend: .baseline,
            confidence: 96,
            nextCheckIn: .now.addingTimeInterval(14 * 86_400),
            symbol: "leaf.fill",
            palette: .fern,
            summary: "A healthy baseline.",
            positiveSigns: [],
            concerns: [],
            nextActions: []
        )
    }
}
